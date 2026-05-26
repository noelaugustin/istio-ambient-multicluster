# -----------------------------------------------------------------------------
# Kind Cluster 1
# -----------------------------------------------------------------------------

resource "kind_cluster" "cluster1" {
  name           = var.cluster1_name
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

# Connect all Cluster 1 Docker containers (nodes) to the shared network.
# Kind names containers as: <cluster-name>-control-plane, <cluster-name>-worker, etc.
resource "null_resource" "cluster1_connect_network" {
  depends_on = [
    kind_cluster.cluster1,
    docker_network.shared,
  ]

  # Re-run if cluster or network changes
  triggers = {
    cluster_id = kind_cluster.cluster1.id
    network_id = docker_network.shared.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      for container in $(docker ps --filter "label=io.x-k8s.kind.cluster=${var.cluster1_name}" --format '{{.Names}}'); do
        echo "Connecting $container to ${var.shared_network_name}..."
        docker network connect "${var.shared_network_name}" "$container" 2>/dev/null || echo "  (already connected)"
      done
    EOT
  }

  # On destroy, disconnect from the shared network before kind removes containers
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      for container in $(docker ps --filter "label=io.x-k8s.kind.cluster" --format '{{.Names}}' 2>/dev/null); do
        docker network disconnect "kind-shared" "$container" 2>/dev/null || true
      done
    EOT
  }
}
