# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "cluster1_name" {
  description = "Name of the first Kind cluster"
  type        = string
  default     = "cluster1"
}

variable "cluster2_name" {
  description = "Name of the second Kind cluster"
  type        = string
  default     = "cluster2"
}

variable "kubernetes_version" {
  description = "Kubernetes version for Kind nodes (maps to a kindest/node image tag)"
  type        = string
  default     = "v1.31.4"
}

# -----------------------------------------------------------------------------
# Docker Network
# -----------------------------------------------------------------------------
variable "shared_network_name" {
  description = "Name of the shared Docker bridge network"
  type        = string
  default     = "kind-shared"
}

variable "shared_network_subnet" {
  description = "CIDR for the shared Docker network"
  type        = string
  default     = "172.20.0.0/16"
}

variable "shared_network_gateway" {
  description = "Gateway IP for the shared Docker network"
  type        = string
  default     = "172.20.0.1"
}

# -----------------------------------------------------------------------------
# MetalLB
# -----------------------------------------------------------------------------
variable "metallb_chart_version" {
  description = "MetalLB Helm chart version"
  type        = string
  default     = "0.14.9"
}

variable "cluster1_metallb_ip_range" {
  description = "MetalLB IP address pool range for Cluster 1 (within shared network subnet)"
  type        = string
  default     = "172.20.10.1-172.20.10.254"
}

variable "cluster2_metallb_ip_range" {
  description = "MetalLB IP address pool range for Cluster 2 (within shared network subnet)"
  type        = string
  default     = "172.20.81.1-172.20.81.254"
}

# -----------------------------------------------------------------------------
# Istio
# -----------------------------------------------------------------------------
variable "istio_version" {
  description = "Istio Helm chart version"
  type        = string
  default     = "1.29.0"
}

variable "mesh_id" {
  description = "Istio mesh ID shared across clusters"
  type        = string
  default     = "mesh1"
}

variable "cluster1_network" {
  description = "Network name for Cluster 1 (Istio topology)"
  type        = string
  default     = "network1"
}

variable "cluster2_network" {
  description = "Network name for Cluster 2 (Istio topology)"
  type        = string
  default     = "network2"
}

variable "certs_dir" {
  description = "Path to directory containing generated CA certificates"
  type        = string
  default     = "../certs"
}
