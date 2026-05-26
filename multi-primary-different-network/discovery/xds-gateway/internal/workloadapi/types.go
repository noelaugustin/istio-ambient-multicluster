// Package workloadapi encodes Istio ambient workload xDS resources
// (type.googleapis.com/istio.workload.Address) as raw protobuf bytes.
//
// Rather than depending on the non-exported workload proto package from
// istio.io/istio, this package hand-encodes the wire format using
// google.golang.org/protobuf/encoding/protowire.
//
// Field numbers and semantics are taken from:
// https://github.com/istio/ztunnel/blob/release-1.29/src/xds/istio/workload/workload.proto
package workloadapi

import (
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/types/known/anypb"
)

// AddressTypeURL is the canonical type URL for the Address message.
const AddressTypeURL = "type.googleapis.com/istio.workload.Address"

// TunnelProtocol is the enum for tunnel protocols.
type TunnelProtocol int32

const (
	TunnelProtocol_NONE  TunnelProtocol = 0
	TunnelProtocol_HBONE TunnelProtocol = 1
)

// WorkloadInfo holds the fields needed to build a Workload protobuf message.
type WorkloadInfo struct {
	// Pod/service IP address (4 bytes for IPv4)
	IPBytes []byte
	// Unique ID: "kubernetes://<cluster>/<namespace>/<name>"
	UID string
	// Kubernetes name
	Name string
	// Kubernetes namespace
	Namespace string
	// SPIFFE trust domain (e.g. "cluster.local")
	TrustDomain string
	// Kubernetes ServiceAccount name
	ServiceAccount string
	// Istio network name (e.g. "network1")
	Network string
	// Tunnel protocol
	TunnelProtocol TunnelProtocol
	// Istio cluster ID (e.g. "cluster1")
	ClusterID string
	// Topology fields
	LocalityRegion string
	LocalityZone   string
}

// MarshalAddress encodes a WorkloadInfo as a raw Address protobuf message.
// The encoding matches the proto definition used by ztunnel 1.29:
//
//	message Address { oneof type { Workload workload = 1; Service service = 2; } }
//	message Workload {
//	  string name                = 1;
//	  string namespace           = 2;
//	  repeated bytes addresses   = 3;
//	  string network             = 4;
//	  TunnelProtocol tunnel_protocol = 5;
//	  string trust_domain        = 6;
//	  string service_account     = 7;
//	  string cluster_id          = 18;
//	  string uid                 = 20;
//	  Locality locality          = 24;
//	}
//	message Locality {
//	  string region = 1;
//	  string zone   = 2;
//	}
func MarshalAddress(w *WorkloadInfo) (*anypb.Any, error) {
	wlBytes := encodeWorkload(w)

	// Address { oneof type { Workload workload = 1; } }
	// field 1, length-delimited (bytes) = tag (1 << 3 | 2)
	addrBytes := protowire.AppendTag(nil, 1, protowire.BytesType)
	addrBytes = protowire.AppendBytes(addrBytes, wlBytes)

	return &anypb.Any{
		TypeUrl: AddressTypeURL,
		Value:   addrBytes,
	}, nil
}

// encodeWorkload serialises the Workload message fields into raw protobuf bytes.
func encodeWorkload(w *WorkloadInfo) []byte {
	var b []byte

	// field 1: string name
	if w.Name != "" {
		b = appendString(b, 1, w.Name)
	}

	// field 2: string namespace
	if w.Namespace != "" {
		b = appendString(b, 2, w.Namespace)
	}

	// field 3: repeated bytes addresses
	if len(w.IPBytes) > 0 {
		b = protowire.AppendTag(b, 3, protowire.BytesType)
		b = protowire.AppendBytes(b, w.IPBytes)
	}

	// field 4: string network
	if w.Network != "" {
		b = appendString(b, 4, w.Network)
	}

	// field 5: TunnelProtocol tunnel_protocol (varint enum)
	if w.TunnelProtocol != TunnelProtocol_NONE {
		b = protowire.AppendTag(b, 5, protowire.VarintType)
		b = protowire.AppendVarint(b, uint64(w.TunnelProtocol))
	}

	// field 6: string trust_domain
	if w.TrustDomain != "" {
		b = appendString(b, 6, w.TrustDomain)
	}

	// field 7: string service_account
	if w.ServiceAccount != "" {
		b = appendString(b, 7, w.ServiceAccount)
	}

	// field 18: string cluster_id
	if w.ClusterID != "" {
		b = appendString(b, 18, w.ClusterID)
	}

	// field 20: string uid
	if w.UID != "" {
		b = appendString(b, 20, w.UID)
	}

	// field 24: Locality
	if w.LocalityRegion != "" || w.LocalityZone != "" {
		var loc []byte
		if w.LocalityRegion != "" {
			loc = appendString(loc, 1, w.LocalityRegion)
		}
		if w.LocalityZone != "" {
			loc = appendString(loc, 2, w.LocalityZone)
		}
		b = protowire.AppendTag(b, 24, protowire.BytesType)
		b = protowire.AppendBytes(b, loc)
	}

	return b
}

// appendString appends a proto string field (tag + length-prefixed bytes).
func appendString(b []byte, fieldNum protowire.Number, s string) []byte {
	b = protowire.AppendTag(b, fieldNum, protowire.BytesType)
	b = protowire.AppendBytes(b, []byte(s))
	return b
}
