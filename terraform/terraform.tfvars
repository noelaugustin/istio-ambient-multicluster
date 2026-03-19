# Default variable values — override in CLI or environment as needed

cluster1_name = "cluster1"
cluster2_name = "cluster2"

kubernetes_version = "v1.31.4"

shared_network_name    = "kind-shared"
shared_network_subnet  = "10.0.0.0/9"
shared_network_gateway = "10.0.0.1"

metallb_chart_version     = "0.14.9"
cluster1_metallb_ip_range = "10.10.0.1-10.10.0.254"
cluster2_metallb_ip_range = "10.81.0.1-10.81.0.254"

# Istio
istio_version    = "1.29.0"
mesh_id          = "mesh1"
cluster1_network = "network1"
cluster2_network = "network2"
certs_dir        = "../certs"
