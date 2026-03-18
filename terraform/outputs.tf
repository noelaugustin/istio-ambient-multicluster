output "cluster1_kubeconfig" {
  description = "Kubeconfig for Kind Cluster 1"
  value       = kind_cluster.cluster1.kubeconfig
  sensitive   = true
}

output "cluster2_kubeconfig" {
  description = "Kubeconfig for Kind Cluster 2"
  value       = kind_cluster.cluster2.kubeconfig
  sensitive   = true
}

output "cluster1_endpoint" {
  description = "API server endpoint for Cluster 1"
  value       = kind_cluster.cluster1.endpoint
}

output "cluster2_endpoint" {
  description = "API server endpoint for Cluster 2"
  value       = kind_cluster.cluster2.endpoint
}

output "shared_network_name" {
  description = "Name of the shared Docker network"
  value       = docker_network.shared.name
}

output "cluster1_metallb_ip_range" {
  description = "MetalLB IP range assigned to Cluster 1"
  value       = var.cluster1_metallb_ip_range
}

output "cluster2_metallb_ip_range" {
  description = "MetalLB IP range assigned to Cluster 2"
  value       = var.cluster2_metallb_ip_range
}

output "istio_mesh_id" {
  description = "Istio mesh ID"
  value       = var.mesh_id
}

output "cluster1_network" {
  description = "Istio network name for Cluster 1"
  value       = var.cluster1_network
}

output "cluster2_network" {
  description = "Istio network name for Cluster 2"
  value       = var.cluster2_network
}
