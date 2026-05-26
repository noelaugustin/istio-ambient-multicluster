// xds-gateway implements the Istio Workload xDS (Delta ADS) API on port 15012.
// It reads workload entries from Valkey (written by endpoint-controller) and
// streams them to connecting ztunnel instances using the istio.workload.Address
// proto messages over gRPC with TLS (shared root CA).
//
// Protocol: Delta ADS (DeltaAggregatedResources) + SotW fallback
// Type URL:  type.googleapis.com/istio.workload.Address
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
	discovery "github.com/envoyproxy/go-control-plane/envoy/service/discovery/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/keepalive"

	"github.com/naugustin/discovery/xds-gateway/internal/workloadapi"
)

const listenPort = ":15012"

// ---------------------------------------------------------------------------
// WorkloadEntry — mirrors the JSON written by endpoint-controller
// ---------------------------------------------------------------------------

type WorkloadEntry struct {
	UID            string `json:"uid"`
	Name           string `json:"name"`
	Namespace      string `json:"namespace"`
	ServiceAccount string `json:"serviceAccount"`
	Network        string `json:"network"`
	Cluster        string `json:"cluster"`
	Region         string `json:"region"`
	AZ             string `json:"az"`
	Node           string `json:"node"`
	IP             string `json:"ip"`
	TrustDomain    string `json:"trustDomain"`
	IsGateway      bool   `json:"isGateway,omitempty"`
}

// ---------------------------------------------------------------------------
// Event fan-out
// ---------------------------------------------------------------------------

type updateEvent struct {
	name     string         // xDS resource name
	workload *WorkloadEntry // nil == deleted
}

type subscription struct {
	ch chan updateEvent
}

// ---------------------------------------------------------------------------
// XDSServer — implements AggregatedDiscoveryServiceServer
// ---------------------------------------------------------------------------

type XDSServer struct {
	redis *redis.Client
	mu    sync.RWMutex
	subs  []*subscription
	discovery.UnimplementedAggregatedDiscoveryServiceServer
}

// DeltaAggregatedResources is the primary handler for ztunnel clients.
func (s *XDSServer) DeltaAggregatedResources(
	stream discovery.AggregatedDiscoveryService_DeltaAggregatedResourcesServer,
) error {
	ctx := stream.Context()

	// ⑴ Read the initial subscription request
	req, err := stream.Recv()
	if err != nil {
		return fmt.Errorf("recv initial request: %w", err)
	}
	nodeID := ""
	if req.Node != nil {
		nodeID = req.Node.Id
	}
	log.Printf("[connect] node=%s typeUrl=%s", nodeID, req.TypeUrl)

	// ⑵ Load all current workloads from Valkey and send initial state
	initResources, err := s.loadAllResources(ctx)
	if err != nil {
		return fmt.Errorf("loading initial workloads: %w", err)
	}

	nonce := fmt.Sprintf("%d", time.Now().UnixNano())
	if err := stream.Send(&discovery.DeltaDiscoveryResponse{
		TypeUrl:   workloadapi.AddressTypeURL,
		Resources: initResources,
		Nonce:     nonce,
	}); err != nil {
		return fmt.Errorf("send initial response: %w", err)
	}
	log.Printf("[%s] sent initial state: %d workloads", nodeID, len(initResources))

	// ⑶ Subscribe to incremental events
	sub := s.subscribe()
	defer s.unsubscribe(sub)

	// Drain ACK/NACK messages so the client stream doesn't back-pressure.
	go func() {
		for {
			if _, err := stream.Recv(); err != nil {
				return
			}
		}
	}()

	// ⑷ Stream incremental updates until the client disconnects
	for {
		select {
		case <-ctx.Done():
			log.Printf("[%s] disconnected", nodeID)
			return nil

		case evt, ok := <-sub.ch:
			if !ok {
				return nil
			}
			nonce := fmt.Sprintf("%d", time.Now().UnixNano())
			var resp *discovery.DeltaDiscoveryResponse

			if evt.workload == nil {
				resp = &discovery.DeltaDiscoveryResponse{
					TypeUrl:          workloadapi.AddressTypeURL,
					RemovedResources: []string{evt.name},
					Nonce:            nonce,
				}
			} else {
				resource, err := s.workloadToResource(evt.name, evt.workload)
				if err != nil {
					log.Printf("[%s] skip workload %s: %v", nodeID, evt.name, err)
					continue
				}
				resp = &discovery.DeltaDiscoveryResponse{
					TypeUrl:   workloadapi.AddressTypeURL,
					Resources: []*discovery.Resource{resource},
					Nonce:     nonce,
				}
			}

			if err := stream.Send(resp); err != nil {
				return fmt.Errorf("send incremental update: %w", err)
			}
		}
	}
}

// StreamAggregatedResources implements SotW ADS for compatibility.
func (s *XDSServer) StreamAggregatedResources(
	stream discovery.AggregatedDiscoveryService_StreamAggregatedResourcesServer,
) error {
	ctx := stream.Context()

	req, err := stream.Recv()
	if err != nil {
		return err
	}
	nodeID := ""
	if req.Node != nil {
		nodeID = req.Node.Id
	}
	log.Printf("[stream-ads] node=%s typeUrl=%s (SotW fallback)", nodeID, req.TypeUrl)

	sub := s.subscribe()
	defer s.unsubscribe(sub)

	if err := s.sendSotWSnapshot(ctx, stream); err != nil {
		return err
	}

	go func() {
		for {
			if _, err := stream.Recv(); err != nil {
				return
			}
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return nil
		case _, ok := <-sub.ch:
			if !ok {
				return nil
			}
			if err := s.sendSotWSnapshot(ctx, stream); err != nil {
				return err
			}
		}
	}
}

func (s *XDSServer) sendSotWSnapshot(
	ctx context.Context,
	stream discovery.AggregatedDiscoveryService_StreamAggregatedResourcesServer,
) error {
	resources, err := s.loadAllResources(ctx)
	if err != nil {
		return err
	}

	resp := &discovery.DiscoveryResponse{
		TypeUrl: workloadapi.AddressTypeURL,
		Nonce:   fmt.Sprintf("%d", time.Now().UnixNano()),
	}
	for _, r := range resources {
		resp.Resources = append(resp.Resources, r.Resource)
	}
	return stream.Send(resp)
}

// ---------------------------------------------------------------------------
// Valkey helpers
// ---------------------------------------------------------------------------

func (s *XDSServer) loadAllResources(ctx context.Context) ([]*discovery.Resource, error) {
	keys, err := s.redis.Keys(ctx, "workload:*").Result()
	if err != nil {
		return nil, fmt.Errorf("keys scan: %w", err)
	}

	var resources []*discovery.Resource
	for _, key := range keys {
		raw, err := s.redis.Get(ctx, key).Result()
		if err != nil {
			continue
		}
		var entry WorkloadEntry
		if err := json.Unmarshal([]byte(raw), &entry); err != nil {
			continue
		}

		name := strings.TrimPrefix(key, "workload:")
		resource, err := s.workloadToResource(name, &entry)
		if err != nil {
			log.Printf("skipping workload %s: %v", key, err)
			continue
		}
		resources = append(resources, resource)
	}
	return resources, nil
}

func (s *XDSServer) workloadToResource(name string, entry *WorkloadEntry) (*discovery.Resource, error) {
	ip := net.ParseIP(entry.IP)
	if ip == nil {
		return nil, fmt.Errorf("invalid IP: %q", entry.IP)
	}

	var ipBytes []byte
	if ip4 := ip.To4(); ip4 != nil {
		ipBytes = ip4
	} else {
		ipBytes = ip.To16()
	}

	uid := fmt.Sprintf("kubernetes://%s/%s/%s", entry.Cluster, entry.Namespace, entry.Name)
	if entry.IsGateway {
		uid = fmt.Sprintf("kubernetes://%s/%s/%s/gateway", entry.Cluster, entry.Namespace, entry.Name)
	}

	sa := entry.ServiceAccount
	if sa == "" && entry.IsGateway {
		sa = "istio-eastwestgateway"
	}

	anyAddr, err := workloadapi.MarshalAddress(&workloadapi.WorkloadInfo{
		IPBytes:        ipBytes,
		UID:            uid,
		Name:           entry.Name,
		Namespace:      entry.Namespace,
		TrustDomain:    entry.TrustDomain,
		ServiceAccount: sa,
		Network:        entry.Network,
		TunnelProtocol: workloadapi.TunnelProtocol_HBONE,
		ClusterID:      entry.Cluster,
		LocalityRegion: entry.Region,
		LocalityZone:   entry.AZ,
	})
	if err != nil {
		return nil, err
	}

	return &discovery.Resource{
		Name:     name,
		Resource: anyAddr,
	}, nil
}

// ---------------------------------------------------------------------------
// Pub/sub — Valkey → ztunnel fan-out
// ---------------------------------------------------------------------------

func (s *XDSServer) startPubSub(ctx context.Context) {
	go func() {
		for {
			if err := s.runPubSub(ctx); err != nil && ctx.Err() == nil {
				log.Printf("pub/sub error: %v — reconnecting in 5s", err)
				select {
				case <-ctx.Done():
					return
				case <-time.After(5 * time.Second):
				}
			}
			if ctx.Err() != nil {
				return
			}
		}
	}()
}

func (s *XDSServer) runPubSub(ctx context.Context) error {
	pubsub := s.redis.Subscribe(ctx, "workload-events")
	defer pubsub.Close()

	ch := pubsub.Channel()
	log.Println("Subscribed to workload-events channel")

	for {
		select {
		case <-ctx.Done():
			return nil
		case msg, ok := <-ch:
			if !ok {
				return fmt.Errorf("pub/sub channel closed")
			}

			var evt struct {
				Event    string         `json:"event"`
				Name     string         `json:"name"`
				Workload *WorkloadEntry `json:"workload,omitempty"`
			}
			if err := json.Unmarshal([]byte(msg.Payload), &evt); err != nil {
				log.Printf("decode pub/sub event: %v", err)
				continue
			}

			ue := updateEvent{name: evt.Name}
			if evt.Event != "del" {
				ue.workload = evt.Workload
			}
			s.broadcast(ue)
		}
	}
}

func (s *XDSServer) subscribe() *subscription {
	sub := &subscription{ch: make(chan updateEvent, 256)}
	s.mu.Lock()
	s.subs = append(s.subs, sub)
	s.mu.Unlock()
	return sub
}

func (s *XDSServer) unsubscribe(sub *subscription) {
	s.mu.Lock()
	for i, v := range s.subs {
		if v == sub {
			s.subs = append(s.subs[:i], s.subs[i+1:]...)
			break
		}
	}
	s.mu.Unlock()
	close(sub.ch)
}

func (s *XDSServer) broadcast(evt updateEvent) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, sub := range s.subs {
		select {
		case sub.ch <- evt:
		default:
			log.Printf("warning: dropping event for slow subscriber")
		}
	}
}

// ---------------------------------------------------------------------------
// TLS
// ---------------------------------------------------------------------------

func loadTLSCredentials(certFile, keyFile string) (credentials.TransportCredentials, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load key pair (%s, %s): %w", certFile, keyFile, err)
	}
	return credentials.NewTLS(&tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequestClientCert, // accept but don't require client certs
		MinVersion:   tls.VersionTLS12,
	}), nil
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	rdb := redis.NewClient(&redis.Options{
		Addr: getEnv("REDIS_ADDR", "valkey-master.discovery.svc.cluster.local:6379"),
	})

	if _, err := rdb.Ping(ctx).Result(); err != nil {
		log.Fatalf("cannot connect to Valkey: %v", err)
	}
	log.Printf("Connected to Valkey at %s", getEnv("REDIS_ADDR", "valkey-master.discovery.svc.cluster.local:6379"))

	srv := &XDSServer{redis: rdb}
	srv.startPubSub(ctx)

	creds, err := loadTLSCredentials(
		getEnv("TLS_CERT_FILE", "/etc/xds-tls/tls.crt"),
		getEnv("TLS_KEY_FILE", "/etc/xds-tls/tls.key"),
	)
	if err != nil {
		log.Fatalf("TLS setup failed: %v", err)
	}

	grpcSrv := grpc.NewServer(
		grpc.Creds(creds),
		grpc.KeepaliveParams(keepalive.ServerParameters{
			MaxConnectionIdle:     5 * time.Minute,
			MaxConnectionAge:      30 * time.Minute,
			MaxConnectionAgeGrace: 5 * time.Second,
			Time:                  2 * time.Minute,
			Timeout:               20 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			MinTime:             60 * time.Second,
			PermitWithoutStream: true,
		}),
	)
	discovery.RegisterAggregatedDiscoveryServiceServer(grpcSrv, srv)

	lis, err := net.Listen("tcp", listenPort)
	if err != nil {
		log.Fatalf("listen %s: %v", listenPort, err)
	}
	log.Printf("xds-gateway listening on %s (TLS, shared root CA)", listenPort)

	go func() {
		<-ctx.Done()
		log.Println("Shutting down gRPC server...")
		grpcSrv.GracefulStop()
	}()

	if err := grpcSrv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
