# -----------------------------------------------------------------------------
# Kind Cluster 3 — Discovery Cluster
# Hosts Valkey, endpoint-controller, and xds-gateway
# MetalLB pool: 10.90.0.x (within kind-shared bridge)
# -----------------------------------------------------------------------------

resource "kind_cluster" "cluster3" {
  name           = var.cluster3_name
  node_image     = "kindest/node:${var.kubernetes_version}"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
    }

    node {
      role = "worker"
    }
  }
}

# Connect all Cluster 3 Docker containers (nodes) to the shared network.
resource "null_resource" "cluster3_connect_network" {
  depends_on = [
    kind_cluster.cluster3,
    docker_network.shared,
  ]

  triggers = {
    cluster_id = kind_cluster.cluster3.id
    network_id = docker_network.shared.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      for container in $(docker ps --filter "label=io.x-k8s.kind.cluster=${var.cluster3_name}" --format '{{.Names}}'); do
        echo "Connecting $container to ${var.shared_network_name}..."
        docker network connect "${var.shared_network_name}" "$container" 2>/dev/null || echo "  (already connected)"
      done
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      for container in $(docker ps --filter "label=io.x-k8s.kind.cluster" --format '{{.Names}}' 2>/dev/null); do
        docker network disconnect "kind-shared" "$container" 2>/dev/null || true
      done
    EOT
  }
}
