terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.7"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# -----------------------------------------------------------------------------
# Provider: Docker (for shared network management)
# -----------------------------------------------------------------------------
provider "docker" {}

# -----------------------------------------------------------------------------
# Provider: Kind (for cluster lifecycle — uses default config)
# -----------------------------------------------------------------------------
provider "kind" {}

# -----------------------------------------------------------------------------
# Provider: Helm — aliased per cluster
# Configured after clusters are created, using kubeconfig from kind_cluster
# -----------------------------------------------------------------------------
provider "helm" {
  alias = "cluster1"
  kubernetes {
    host                   = kind_cluster.cluster1.endpoint
    client_certificate     = kind_cluster.cluster1.client_certificate
    client_key             = kind_cluster.cluster1.client_key
    cluster_ca_certificate = kind_cluster.cluster1.cluster_ca_certificate
  }
}

provider "helm" {
  alias = "cluster2"
  kubernetes {
    host                   = kind_cluster.cluster2.endpoint
    client_certificate     = kind_cluster.cluster2.client_certificate
    client_key             = kind_cluster.cluster2.client_key
    cluster_ca_certificate = kind_cluster.cluster2.cluster_ca_certificate
  }
}

# -----------------------------------------------------------------------------
# Provider: Kubernetes — aliased per cluster
# Used for namespaces, secrets (cacerts), and labels
# -----------------------------------------------------------------------------
provider "kubernetes" {
  alias                  = "cluster1"
  host                   = kind_cluster.cluster1.endpoint
  client_certificate     = kind_cluster.cluster1.client_certificate
  client_key             = kind_cluster.cluster1.client_key
  cluster_ca_certificate = kind_cluster.cluster1.cluster_ca_certificate
}

provider "kubernetes" {
  alias                  = "cluster2"
  host                   = kind_cluster.cluster2.endpoint
  client_certificate     = kind_cluster.cluster2.client_certificate
  client_key             = kind_cluster.cluster2.client_key
  cluster_ca_certificate = kind_cluster.cluster2.cluster_ca_certificate
}
