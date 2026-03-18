# Istio Ambient Mesh Multi-Cluster Playground

This repository contains a complete Infrastructure-as-Code (IaC) setup for deploying a **Multi-Primary, Multi-Network Istio Ambient Mesh** across two local Kubernetes clusters using `kind` and `terraform`.

The architecture demonstrates a high-availability mesh using Istio's sidecar-less Ambient data plane (Ztunnel for L4, Waypoint proxies for L7), cross-cluster service discovery, and local MetalLB load balancers.

## Architecture Highlights
- **2 K8s Clusters (`cluster1` & `cluster2`)** running in Docker containers via Kind, sharing the `kind-shared` Docker bridge network.
- **MetalLB Load Balancing:** Each cluster has a dedicated IP address pool assigned to its load balancers natively within the bridge network to avoid overlapping (`172.20.10.x` and `172.20.81.x`).
- **Istio 1.29 (Ambient Mode):** `istio-base`, `istiod`, `istio-cni`, and `ztunnel` installed entirely declaratively via Terraform Helm releases (zero `istioctl` command-line dependencies).
- **Multi-Network East-West Gateways:** Deployed natively using Kubernetes Gateway API to facilitate cross-cluster communication.
- **Sample Application:** Automatically deploys `sleep` and `helloworld` clients/services. `helloworld` is explicitly labeled as a global mesh service (`istio.io/global="true"`) routing through L7 Waypoint Proxies, demonstrating seamless active-active failover across the clusters.

---

## Prerequisites

Ensure the following tools are installed on your host machine before starting:

1. **[Docker Engine / Desktop](https://docs.docker.com/engine/install/)** (running)
2. **[Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)** (`v0.20.0` or higher)
3. **[Terraform](https://developer.hashicorp.com/terraform/downloads)** (`v1.5.0` or higher)
4. **[kubectl](https://kubernetes.io/docs/tasks/tools/)** 
5. **[Helm](https://helm.sh/docs/intro/install/)**

---

## Setup Instructions

All infrastructure management is handled completely autonomously via Terraform. However, you must first generate the root Identity CA certificates for the mesh.

### Step 1: Generate Mesh Certificates
Istio requires a shared Root CA to establish trust securely across disjoint clusters. A script is provided to generate these locally.

Open your terminal and run:
```bash
cd certs/
./gen-certs.sh
cd ..
```
*This generates a Root CA and specific intermediate certs for `cluster1` and `cluster2`, which Terraform will then mount securely into the clusters as Kubernetes Secrets.*

### Step 2: Provision Infrastructure
With the certificates prepared, you can now instruct Terraform to build the clusters, deploy MetalLB, install Istio, and launch the sample microservices.

```bash
cd terraform/

# Initialize the Terraform providers
terraform init

# Apply the infrastructure (this will take ~3-5 minutes)
terraform apply
```

Review the planned resources and type `yes` to accept. 

Once complete, Terraform will automatically configure your local `~/.kube/config` with contexts for `kind-cluster1` and `kind-cluster2`.

### Step 3: Verify the Ambient Mesh
You can instantly test the L4 Ztunnel and cross-cluster service routing using the `sleep` application deployed to cluster 1. 

From any terminal window, run a curl burst to the `helloworld` service from `cluster1`:

```bash
# Verify responses alternate between v1 (cluster1) and v2 (cluster2) traversing the East-West Gateway
kubectl exec deploy/sleep --context kind-cluster1 -n sample -- curl -sS http://helloworld:5000/hello
```

Because the `helloworld` service is permanently synced by Terraform with the `istio.io/use-waypoint` and `istio.io/global="true"` labels, this traffic is not only encrypted dynamically by Ztunnel but load-balanced flawlessly across the two discrete Kind environments!

---

## Cleanup
To destroy the entire virtual lab and completely remove the Docker networks and state:

```bash
cd terraform/
terraform destroy -auto-approve
```
