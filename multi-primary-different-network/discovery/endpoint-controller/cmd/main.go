// endpoint-controller watches pods and east-west gateway services across
// cluster1 and cluster2, writing topology-enriched workload entries to Valkey.
// Upstream clients (xds-gateway) subscribe to changes via Valkey pub/sub.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

// ClusterConfig holds identity and topology info for one watched cluster.
type ClusterConfig struct {
	Name           string
	KubeconfigPath string
	Network        string
	Region         string
	AZ             string
}

// WorkloadEntry is the canonical JSON record stored in Valkey.
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

// PubSubEvent is the message published on the "workload-events" channel.
type PubSubEvent struct {
	Event    string         `json:"event"`             // "add" | "del"
	Name     string         `json:"name"`              // xDS resource name
	Workload *WorkloadEntry `json:"workload,omitempty"` // nil on delete
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	rdb := redis.NewClient(&redis.Options{
		Addr:     getEnvOrDefault("REDIS_ADDR", "valkey.discovery.svc.cluster.local:6379"),
		Password: "",
		DB:       0,
	})

	if _, err := rdb.Ping(ctx).Result(); err != nil {
		log.Fatalf("cannot connect to Valkey at %s: %v", getEnvOrDefault("REDIS_ADDR", "valkey.discovery.svc.cluster.local:6379"), err)
	}
	log.Println("Connected to Valkey")

	clusters := []ClusterConfig{
		{
			Name:           getEnvOrDefault("CLUSTER1_NAME", "cluster1"),
			KubeconfigPath: "/etc/kubeconfigs/cluster1",
			Network:        getEnvOrDefault("CLUSTER1_NETWORK", "network1"),
			Region:         getEnvOrDefault("CLUSTER1_REGION", "local"),
			AZ:             getEnvOrDefault("CLUSTER1_AZ", "zone-a"),
		},
		{
			Name:           getEnvOrDefault("CLUSTER2_NAME", "cluster2"),
			KubeconfigPath: "/etc/kubeconfigs/cluster2",
			Network:        getEnvOrDefault("CLUSTER2_NETWORK", "network2"),
			Region:         getEnvOrDefault("CLUSTER2_REGION", "local"),
			AZ:             getEnvOrDefault("CLUSTER2_AZ", "zone-b"),
		},
	}

	for _, cfg := range clusters {
		go watchCluster(ctx, cfg, rdb)
	}

	<-ctx.Done()
	log.Println("Shutting down endpoint-controller")
}

// ---------------------------------------------------------------------------
// Per-cluster watcher
// ---------------------------------------------------------------------------

func watchCluster(ctx context.Context, cfg ClusterConfig, rdb *redis.Client) {
	log.Printf("[%s] Starting cluster watcher (network=%s, region=%s, az=%s)", cfg.Name, cfg.Network, cfg.Region, cfg.AZ)

	restCfg, err := clientcmd.BuildConfigFromFlags("", cfg.KubeconfigPath)
	if err != nil {
		log.Fatalf("[%s] failed to load kubeconfig from %s: %v", cfg.Name, cfg.KubeconfigPath, err)
	}

	clientset, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		log.Fatalf("[%s] failed to create k8s client: %v", cfg.Name, err)
	}

	factory := informers.NewSharedInformerFactory(clientset, 60*time.Second)

	// --- Pod watcher ---
	podInformer := factory.Core().V1().Pods().Informer()
	podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			handlePodChange(ctx, obj, cfg, rdb)
		},
		UpdateFunc: func(_, obj interface{}) {
			handlePodChange(ctx, obj, cfg, rdb)
		},
		DeleteFunc: func(obj interface{}) {
			handlePodDelete(ctx, obj, cfg, rdb)
		},
	})

	// --- Service watcher (east-west gateways only) ---
	svcInformer := factory.Core().V1().Services().Informer()
	svcInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			handleServiceChange(ctx, obj, cfg, rdb)
		},
		UpdateFunc: func(_, obj interface{}) {
			handleServiceChange(ctx, obj, cfg, rdb)
		},
		DeleteFunc: func(obj interface{}) {
			handleServiceDelete(ctx, obj, cfg, rdb)
		},
	})

	stopCh := make(chan struct{})
	go func() {
		<-ctx.Done()
		close(stopCh)
	}()

	factory.Start(stopCh)
	if !cache.WaitForCacheSync(stopCh, podInformer.HasSynced, svcInformer.HasSynced) {
		log.Printf("[%s] timed out waiting for cache sync", cfg.Name)
		return
	}

	log.Printf("[%s] Cache synced — watching pods and services", cfg.Name)
	<-stopCh
}

// ---------------------------------------------------------------------------
// Pod handlers
// ---------------------------------------------------------------------------

func isPodReady(pod *corev1.Pod) bool {
	if pod.DeletionTimestamp != nil {
		return false
	}
	if pod.Status.PodIP == "" {
		return false
	}
	if pod.Status.Phase != corev1.PodRunning {
		return false
	}
	// Require at least one container ready
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.Ready {
			return true
		}
	}
	return false
}

func podResourceName(cfg ClusterConfig, pod *corev1.Pod) string {
	return fmt.Sprintf("%s/%s/%s", cfg.Name, pod.Namespace, pod.Name)
}

func handlePodChange(ctx context.Context, obj interface{}, cfg ClusterConfig, rdb *redis.Client) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return
	}
	if !isPodReady(pod) {
		// Pod not yet ready or being deleted — remove if present
		handlePodDelete(ctx, obj, cfg, rdb)
		return
	}

	sa := pod.Spec.ServiceAccountName
	if sa == "" {
		sa = "default"
	}

	entry := &WorkloadEntry{
		UID:            string(pod.UID),
		Name:           pod.Name,
		Namespace:      pod.Namespace,
		ServiceAccount: sa,
		Network:        cfg.Network,
		Cluster:        cfg.Name,
		Region:         cfg.Region,
		AZ:             cfg.AZ,
		Node:           pod.Spec.NodeName,
		IP:             pod.Status.PodIP,
		TrustDomain:    "cluster.local",
	}

	resourceName := podResourceName(cfg, pod)
	key := "workload:" + resourceName

	data, err := json.Marshal(entry)
	if err != nil {
		log.Printf("[%s] failed to marshal pod %s: %v", cfg.Name, pod.Name, err)
		return
	}

	if err := rdb.Set(ctx, key, data, 0).Err(); err != nil {
		log.Printf("[%s] failed to set key %s in Valkey: %v", cfg.Name, key, err)
		return
	}

	pub := PubSubEvent{Event: "add", Name: resourceName, Workload: entry}
	publish(ctx, rdb, pub, cfg.Name)
}

func handlePodDelete(ctx context.Context, obj interface{}, cfg ClusterConfig, rdb *redis.Client) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		// tombstone
		if ts, ok := obj.(cache.DeletedFinalStateUnknown); ok {
			pod, ok = ts.Obj.(*corev1.Pod)
			if !ok {
				return
			}
		} else {
			return
		}
	}

	resourceName := podResourceName(cfg, pod)
	key := "workload:" + resourceName

	if err := rdb.Del(ctx, key).Err(); err != nil {
		log.Printf("[%s] failed to delete key %s from Valkey: %v", cfg.Name, key, err)
	}

	pub := PubSubEvent{Event: "del", Name: resourceName}
	publish(ctx, rdb, pub, cfg.Name)
}

// ---------------------------------------------------------------------------
// Service handlers — east-west gateways only
// ---------------------------------------------------------------------------

func isEastWestGateway(svc *corev1.Service) bool {
	return svc.Labels["app"] == "istio-eastwestgateway" &&
		svc.Namespace == "istio-system"
}

func svcResourceName(cfg ClusterConfig, svc *corev1.Service) string {
	return fmt.Sprintf("gw/%s/%s/%s", cfg.Name, svc.Namespace, svc.Name)
}

func handleServiceChange(ctx context.Context, obj interface{}, cfg ClusterConfig, rdb *redis.Client) {
	svc, ok := obj.(*corev1.Service)
	if !ok {
		return
	}
	if !isEastWestGateway(svc) {
		return
	}
	if len(svc.Status.LoadBalancer.Ingress) == 0 {
		log.Printf("[%s] east-west gateway %s has no LB IP yet, skipping", cfg.Name, svc.Name)
		return
	}

	lbIP := svc.Status.LoadBalancer.Ingress[0].IP
	if lbIP == "" {
		lbIP = svc.Status.LoadBalancer.Ingress[0].Hostname
	}
	if lbIP == "" {
		return
	}

	entry := &WorkloadEntry{
		UID:         string(svc.UID),
		Name:        svc.Name,
		Namespace:   svc.Namespace,
		Network:     cfg.Network,
		Cluster:     cfg.Name,
		Region:      cfg.Region,
		AZ:          cfg.AZ,
		IP:          lbIP,
		TrustDomain: "cluster.local",
		IsGateway:   true,
	}

	resourceName := svcResourceName(cfg, svc)
	key := "workload:" + resourceName

	data, err := json.Marshal(entry)
	if err != nil {
		log.Printf("[%s] failed to marshal service %s: %v", cfg.Name, svc.Name, err)
		return
	}

	if err := rdb.Set(ctx, key, data, 0).Err(); err != nil {
		log.Printf("[%s] failed to set gateway key %s: %v", cfg.Name, key, err)
		return
	}

	pub := PubSubEvent{Event: "add", Name: resourceName, Workload: entry}
	publish(ctx, rdb, pub, cfg.Name)
	log.Printf("[%s] Registered east-west gateway %s → %s (network=%s)", cfg.Name, svc.Name, lbIP, cfg.Network)
}

func handleServiceDelete(ctx context.Context, obj interface{}, cfg ClusterConfig, rdb *redis.Client) {
	svc, ok := obj.(*corev1.Service)
	if !ok {
		if ts, ok := obj.(cache.DeletedFinalStateUnknown); ok {
			svc, ok = ts.Obj.(*corev1.Service)
			if !ok {
				return
			}
		} else {
			return
		}
	}
	if !isEastWestGateway(svc) {
		return
	}

	resourceName := svcResourceName(cfg, svc)
	key := "workload:" + resourceName

	rdb.Del(ctx, key)
	pub := PubSubEvent{Event: "del", Name: resourceName}
	publish(ctx, rdb, pub, cfg.Name)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func publish(ctx context.Context, rdb *redis.Client, evt PubSubEvent, clusterName string) {
	data, err := json.Marshal(evt)
	if err != nil {
		log.Printf("[%s] failed to marshal event: %v", clusterName, err)
		return
	}
	if err := rdb.Publish(ctx, "workload-events", data).Err(); err != nil {
		log.Printf("[%s] failed to publish event for %s: %v", clusterName, evt.Name, err)
		return
	}
	log.Printf("[%s] published event: event=%s name=%s", clusterName, evt.Event, evt.Name)
}

func getEnvOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
