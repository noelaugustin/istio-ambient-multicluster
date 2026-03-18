# =============================================================================
# Istio 1.29 Ambient Mesh — Multi-Primary on Different Networks
# =============================================================================
# Installation order per cluster:
#   1. Gateway API CRDs
#   2. istio-system namespace + network label
#   3. cacerts secret (shared root CA + per-cluster intermediate CA)
#   4. istio-base (Helm)
#   5. istiod (Helm) — ambient profile + multi-cluster config
#   6. istio-cni (Helm) — ambient profile
#   7. ztunnel (Helm)
#   8. East-west gateway (K8s Gateway resource)
#   9. Remote secrets for endpoint discovery
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Gateway API CRDs — required before Istio installation
# -----------------------------------------------------------------------------

resource "null_resource" "gateway_api_crds_cluster1" {
  depends_on = [kind_cluster.cluster1]

  triggers = {
    cluster_id = kind_cluster.cluster1.id
  }

  provisioner "local-exec" {
    command = "kubectl --context kind-${var.cluster1_name} apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml"
  }
}

resource "null_resource" "gateway_api_crds_cluster2" {
  depends_on = [kind_cluster.cluster2]

  triggers = {
    cluster_id = kind_cluster.cluster2.id
  }

  provisioner "local-exec" {
    command = "kubectl --context kind-${var.cluster2_name} apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml"
  }
}

# -----------------------------------------------------------------------------
# 2. istio-system namespace + network labels
# -----------------------------------------------------------------------------

resource "kubernetes_namespace" "istio_system_cluster1" {
  provider = kubernetes.cluster1

  metadata {
    name = "istio-system"
    labels = {
      "topology.istio.io/network" = var.cluster1_network
    }
  }

  depends_on = [kind_cluster.cluster1]
}

resource "kubernetes_namespace" "istio_system_cluster2" {
  provider = kubernetes.cluster2

  metadata {
    name = "istio-system"
    labels = {
      "topology.istio.io/network" = var.cluster2_network
    }
  }

  depends_on = [kind_cluster.cluster2]
}

# -----------------------------------------------------------------------------
# 3. cacerts secrets — shared root CA + per-cluster intermediate CAs
# -----------------------------------------------------------------------------

resource "kubernetes_secret" "cacerts_cluster1" {
  provider = kubernetes.cluster1

  metadata {
    name      = "cacerts"
    namespace = "istio-system"
  }

  data = {
    "ca-cert.pem"    = file("${var.certs_dir}/cluster1/ca-cert.pem")
    "ca-key.pem"     = file("${var.certs_dir}/cluster1/ca-key.pem")
    "root-cert.pem"  = file("${var.certs_dir}/cluster1/root-cert.pem")
    "cert-chain.pem" = file("${var.certs_dir}/cluster1/cert-chain.pem")
  }

  type = "generic"

  depends_on = [kubernetes_namespace.istio_system_cluster1]
}

resource "kubernetes_secret" "cacerts_cluster2" {
  provider = kubernetes.cluster2

  metadata {
    name      = "cacerts"
    namespace = "istio-system"
  }

  data = {
    "ca-cert.pem"    = file("${var.certs_dir}/cluster2/ca-cert.pem")
    "ca-key.pem"     = file("${var.certs_dir}/cluster2/ca-key.pem")
    "root-cert.pem"  = file("${var.certs_dir}/cluster2/root-cert.pem")
    "cert-chain.pem" = file("${var.certs_dir}/cluster2/cert-chain.pem")
  }

  type = "generic"

  depends_on = [kubernetes_namespace.istio_system_cluster2]
}

# -----------------------------------------------------------------------------
# 4. istio-base — CRDs and cluster-scoped resources
# -----------------------------------------------------------------------------

resource "helm_release" "istio_base_cluster1" {
  provider = helm.cluster1

  name             = "istio-base"
  namespace        = "istio-system"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  create_namespace = false

  wait    = true
  timeout = 120

  depends_on = [
    kubernetes_secret.cacerts_cluster1,
    null_resource.gateway_api_crds_cluster1,
    null_resource.metallb_config_cluster1,
  ]
}

resource "helm_release" "istio_base_cluster2" {
  provider = helm.cluster2

  name             = "istio-base"
  namespace        = "istio-system"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  create_namespace = false

  wait    = true
  timeout = 120

  depends_on = [
    kubernetes_secret.cacerts_cluster2,
    null_resource.gateway_api_crds_cluster2,
    null_resource.metallb_config_cluster2,
  ]
}

# -----------------------------------------------------------------------------
# 5. istiod — control plane (ambient profile + multi-cluster)
# -----------------------------------------------------------------------------

resource "helm_release" "istiod_cluster1" {
  provider = helm.cluster1

  name             = "istiod"
  namespace        = "istio-system"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "istiod"
  version          = var.istio_version
  create_namespace = false

  wait          = true
  wait_for_jobs = true
  timeout       = 300

  set {
    name  = "profile"
    value = "ambient"
  }
  set {
    name  = "global.meshID"
    value = var.mesh_id
  }
  set {
    name  = "global.multiCluster.clusterName"
    value = var.cluster1_name
  }
  set {
    name  = "global.network"
    value = var.cluster1_network
  }
  set {
    name  = "env.AMBIENT_ENABLE_MULTI_NETWORK"
    value = "true"
  }
  set {
    name  = "env.AMBIENT_ENABLE_BAGGAGE"
    value = "true"
  }

  depends_on = [helm_release.istio_base_cluster1]
}

resource "helm_release" "istiod_cluster2" {
  provider = helm.cluster2

  name             = "istiod"
  namespace        = "istio-system"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "istiod"
  version          = var.istio_version
  create_namespace = false

  wait          = true
  wait_for_jobs = true
  timeout       = 300

  set {
    name  = "profile"
    value = "ambient"
  }
  set {
    name  = "global.meshID"
    value = var.mesh_id
  }
  set {
    name  = "global.multiCluster.clusterName"
    value = var.cluster2_name
  }
  set {
    name  = "global.network"
    value = var.cluster2_network
  }
  set {
    name  = "env.AMBIENT_ENABLE_MULTI_NETWORK"
    value = "true"
  }
  set {
    name  = "env.AMBIENT_ENABLE_BAGGAGE"
    value = "true"
  }

  depends_on = [helm_release.istio_base_cluster2]
}

# -----------------------------------------------------------------------------
# 6. istio-cni — CNI node agent (ambient mode)
# -----------------------------------------------------------------------------

resource "helm_release" "istio_cni_cluster1" {
  provider = helm.cluster1

  name             = "istio-cni"
  namespace        = "istio-system"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "cni"
  version          = var.istio_version
  create_namespace = false

  wait    = true
  timeout = 120

  set {
    name  = "profile"
    value = "ambient"
  }

  depends_on = [helm_release.istiod_cluster1]
}

resource "helm_release" "istio_cni_cluster2" {
  provider = helm.cluster2

  name             = "istio-cni"
  namespace        = "istio-system"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "cni"
  version          = var.istio_version
  create_namespace = false

  wait    = true
  timeout = 120

  set {
    name  = "profile"
    value = "ambient"
  }

  depends_on = [helm_release.istiod_cluster2]
}

# -----------------------------------------------------------------------------
# 7. ztunnel — per-node data plane proxy
# -----------------------------------------------------------------------------

resource "helm_release" "ztunnel_cluster1" {
  provider = helm.cluster1

  name             = "ztunnel"
  namespace        = "istio-system"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "ztunnel"
  version          = var.istio_version
  create_namespace = false

  wait    = true
  timeout = 120

  set {
    name  = "multiCluster.clusterName"
    value = var.cluster1_name
  }
  set {
    name  = "global.network"
    value = var.cluster1_network
  }

  depends_on = [helm_release.istio_cni_cluster1]
}

resource "helm_release" "ztunnel_cluster2" {
  provider = helm.cluster2

  name             = "ztunnel"
  namespace        = "istio-system"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "ztunnel"
  version          = var.istio_version
  create_namespace = false

  wait    = true
  timeout = 120

  set {
    name  = "multiCluster.clusterName"
    value = var.cluster2_name
  }
  set {
    name  = "global.network"
    value = var.cluster2_network
  }

  depends_on = [helm_release.istio_cni_cluster2]
}

# -----------------------------------------------------------------------------
# 8. East-West Gateways — for cross-cluster traffic via HBONE
# -----------------------------------------------------------------------------

resource "null_resource" "eastwest_gateway_cluster1" {
  depends_on = [helm_release.ztunnel_cluster1]

  triggers = {
    cluster_id = kind_cluster.cluster1.id
    network    = var.cluster1_network
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context kind-${var.cluster1_name} apply -f - <<EOF
      kind: Gateway
      apiVersion: gateway.networking.k8s.io/v1
      metadata:
        name: istio-eastwestgateway
        namespace: istio-system
        labels:
          topology.istio.io/network: "${var.cluster1_network}"
      spec:
        gatewayClassName: istio-east-west
        listeners:
          - name: mesh
            port: 15008
            protocol: HBONE
            tls:
              mode: Terminate
              options:
                gateway.istio.io/tls-terminate-mode: ISTIO_MUTUAL
      EOF
    EOT
  }
}

resource "null_resource" "eastwest_gateway_cluster2" {
  depends_on = [helm_release.ztunnel_cluster2]

  triggers = {
    cluster_id = kind_cluster.cluster2.id
    network    = var.cluster2_network
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context kind-${var.cluster2_name} apply -f - <<EOF
      kind: Gateway
      apiVersion: gateway.networking.k8s.io/v1
      metadata:
        name: istio-eastwestgateway
        namespace: istio-system
        labels:
          topology.istio.io/network: "${var.cluster2_network}"
      spec:
        gatewayClassName: istio-east-west
        listeners:
          - name: mesh
            port: 15008
            protocol: HBONE
            tls:
              mode: Terminate
              options:
                gateway.istio.io/tls-terminate-mode: ISTIO_MUTUAL
      EOF
    EOT
  }
}

# -----------------------------------------------------------------------------
# 9. Remote Secrets — endpoint discovery across clusters
# -----------------------------------------------------------------------------

resource "kubernetes_secret" "remote_secret_cluster2_in_cluster1" {
  provider = kubernetes.cluster1

  metadata {
    name      = "istio-remote-secret-${var.cluster2_name}"
    namespace = "istio-system"
    labels = {
      "istio/multiCluster" = "true"
    }
    annotations = {
      "networking.istio.io/cluster" = var.cluster2_name
    }
  }

  data = {
    "${var.cluster2_name}" = <<-EOT
      apiVersion: v1
      kind: Config
      clusters:
      - name: ${var.cluster2_name}
        cluster:
          server: https://${var.cluster2_name}-control-plane:6443
          certificate-authority-data: ${base64encode(kind_cluster.cluster2.cluster_ca_certificate)}
      users:
      - name: ${var.cluster2_name}
        user:
          client-certificate-data: ${base64encode(kind_cluster.cluster2.client_certificate)}
          client-key-data: ${base64encode(kind_cluster.cluster2.client_key)}
      contexts:
      - name: ${var.cluster2_name}
        context:
          cluster: ${var.cluster2_name}
          user: ${var.cluster2_name}
      current-context: ${var.cluster2_name}
    EOT
  }

  type = "Opaque"

  depends_on = [
    helm_release.istiod_cluster1,
    helm_release.istiod_cluster2,
  ]
}

resource "kubernetes_secret" "remote_secret_cluster1_in_cluster2" {
  provider = kubernetes.cluster2

  metadata {
    name      = "istio-remote-secret-${var.cluster1_name}"
    namespace = "istio-system"
    labels = {
      "istio/multiCluster" = "true"
    }
    annotations = {
      "networking.istio.io/cluster" = var.cluster1_name
    }
  }

  data = {
    "${var.cluster1_name}" = <<-EOT
      apiVersion: v1
      kind: Config
      clusters:
      - name: ${var.cluster1_name}
        cluster:
          server: https://${var.cluster1_name}-control-plane:6443
          certificate-authority-data: ${base64encode(kind_cluster.cluster1.cluster_ca_certificate)}
      users:
      - name: ${var.cluster1_name}
        user:
          client-certificate-data: ${base64encode(kind_cluster.cluster1.client_certificate)}
          client-key-data: ${base64encode(kind_cluster.cluster1.client_key)}
      contexts:
      - name: ${var.cluster1_name}
        context:
          cluster: ${var.cluster1_name}
          user: ${var.cluster1_name}
      current-context: ${var.cluster1_name}
    EOT
  }

  type = "Opaque"

  depends_on = [
    helm_release.istiod_cluster1,
    helm_release.istiod_cluster2,
  ]
}
