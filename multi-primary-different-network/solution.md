# Multi-Cluster Ambient Mesh Implementation Steps

The following steps detail the end-to-end architecture and configurations implemented to guarantee that the Istio 1.29 Ambient Mesh successfully bridges both isolated Kubernetes clusters to achieve seamless cross-cluster global load balancing.

### 1. Underlying Networking Infrastructure
Before Istio could route traffic natively, the nodes had to sit on the same physical routing plane.
- **Shared Bridge Extranet:** We deployed both Kind clusters (`cluster1`, `cluster2`) onto a unified Docker network (`kind-shared`) provisioned with a `10.0.0.0/9` subnet.
- **MetalLB Load Balancing:** Since Kind doesn't natively expose `LoadBalancer` services, we deployed MetalLB into both clusters in robust L2-mode with distinct `10.10.x.x` and `10.81.x.x` IP ranges.

### 2. Mesh Common Trust (mTLS Security)
A multi-cluster mesh fundamentally fails without a unified cryptographic root to trust cross-cluster traffic.
- **Custom Root CA:** We generated a private self-signed certificate authority (`gen-certs.sh`) and specific intermediate wildcard certificates.
- **Kubernetes Securing:** We injected these into both clusters natively as `istio-system/cacerts` Secrets before booting up the control planes.

### 3. Multi-Primary Istio Configuration
We explicitly configured the `istiod` control planes declaratively via Terraform Helm charts to acknowledge they belong to a broader topology.
- Forced `global.meshID=mesh1` so both clusters recognize they are peers.
- Assigned discrete sub-network mappings (`network1` and `network2`) and `clusterName` identifiers. 

### 4. Endpoint Discovery (API Server Access)
By default, the *Istio Control Plane (istiod)* running on `cluster1` is entirely blind to the pods running on `cluster2`.
- We extracted a restricted, headless `kubeconfig` token from `cluster1`.
- We stored this token physically inside `cluster2` as a generic Kubernetes remote Secret (`istio-remote-secret-cluster1`).
- We labeled it with `istio/multiCluster=true` and annotated it with `networking.istio.io/cluster: cluster1`, commanding `istiod` to begin ingesting the workload endpoints from the other cluster's API Server.

### 5. Transport Tunnels (East-West Gateway)
Because the clusters are on physically isolated `network1` and `network2` definitions, they rely entirely on the East-West Gateways to act as an edge router into the opposing clusters natively.
- Deployed the **Kubernetes Gateway API CRDs**.
- Created an `istio-eastwestgateway` object assigned to port `15008`.
- Set the traffic mode exclusively to Istio's proprietary `HBONE` (HTTP-Based Overlay Network Environment) payload configured for `ISTIO_MUTUAL` zero-trust TLS intersection.

### 6. Ambient Mesh Workloads
Finally, we shifted your microservices onto the Mesh Data Plane infrastructure.
- Deployed the `istio-cni` and `ztunnel` components via Helm to transparently intercept Node pod traffic.
- Labeled the `sample` namespace actively with `istio.io/dataplane-mode=ambient` to seamlessly enroll `sleep` and `helloworld` inside the L4 hardware-accelerated proxy overlay.
- Added the `istio.io/use-waypoint: waypoint` label to offload rigorous L7 policies.

### 7. Overriding ClusterIP Local Isolation (Global Routing Fix)
When utilizing default overlapping Kind subnets (`10.244.x.x`), Ztunnel intentionally isolates traffic bounds strictly by local routing tables. We had to forcefully circumvent this constraint.
- **The Core Fix:** We physically patched the `helloworld` service template mapping to inject the `istio.io/global="true"` label natively.
- This explicit flag bypasses standard ClusterIP containment, instructing Ztunnel to actively shift connections across to the `10.x` MetalLB East-West IPs belonging to the opposing remote instances!

### 8. L7 Waypoint Proxies (Envoy Layer)
To enable deep L7 processing (like HTTP routing, retries, authorization policies, and fault injection) which Ztunnel intentionally avoids, we deployed Envoy-based Waypoint Proxies.
- **Gateway Deployment:** Instead of a complex installation, the Waypoint proxy is natively provisioned using the Kubernetes Gateway API. We deployed a standard `Gateway` resource (named `waypoint`) into the `sample` namespace, bound to the `istio-waypoint` GatewayClass. `istiod` automatically detects this CRD and auto-provisions an Envoy deployment to act as the namespace waypoint.
- **Service Enrollment:** To physically route traffic through the waypoint, we added the `istio.io/use-waypoint: waypoint` label to the `helloworld` service. Now, whenever the Ztunnel detects traffic destined for `helloworld`, it intercepts and forwards it through the Waypoint proxy for L7 inspection before delivering the traffic to the destination pod!
