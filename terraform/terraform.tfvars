# Default variable values — override in CLI or environment as needed

cluster1_name = "cluster1"
cluster2_name = "cluster2"

kubernetes_version = "v1.31.4"

shared_network_name    = "kind-shared"
shared_network_subnet  = "172.20.0.0/16"
shared_network_gateway = "172.20.0.1"

metallb_chart_version     = "0.14.9"
cluster1_metallb_ip_range = "172.20.10.1-172.20.10.254"
cluster2_metallb_ip_range = "172.20.81.1-172.20.81.254"

# Istio
istio_version    = "1.29.0"
mesh_id          = "mesh1"
cluster1_network = "network1"
cluster2_network = "network2"
certs_dir        = "../certs"
