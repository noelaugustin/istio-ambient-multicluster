# -----------------------------------------------------------------------------
# Kind Cluster 2
# -----------------------------------------------------------------------------

resource "kind_cluster" "cluster2" {
  name           = var.cluster2_name
  node_image     = "kindest/node:${var.kubernetes_version}"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    networking {
      pod_subnet     = var.cluster2_pod_subnet
      service_subnet = var.cluster2_service_subnet
    }

    node {
      role = "control-plane"
    }

    node {
      role = "worker"
    }
  }
}

# Connect all Cluster 2 Docker containers (nodes) to the shared network.
resource "null_resource" "cluster2_connect_network" {
  depends_on = [
    kind_cluster.cluster2,
    docker_network.shared,
  ]

  triggers = {
    cluster_id = kind_cluster.cluster2.id
    network_id = docker_network.shared.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      for container in $(docker ps --filter "label=io.x-k8s.kind.cluster=${var.cluster2_name}" --format '{{.Names}}'); do
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
