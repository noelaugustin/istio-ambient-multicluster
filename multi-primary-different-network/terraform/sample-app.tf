# =============================================================================
# Istio Sample Application Deployment
# =============================================================================
# Deploys `istio-sample-app` Helm chart to both clusters in the `sample` namespace.
# The namespace is labeled for ambient mode (ztunnel data plane).
# =============================================================================

# -----------------------------------------------------------------------------
# Namespaces
# -----------------------------------------------------------------------------

resource "kubernetes_namespace" "sample_cluster1" {
  provider = kubernetes.cluster1

  metadata {
    name = "sample"
    labels = {
      "istio.io/dataplane-mode"   = "ambient"
      "topology.istio.io/network" = var.cluster1_network
    }
  }

  depends_on = [
    helm_release.ztunnel_cluster1,
    null_resource.eastwest_gateway_cluster1,
  ]
}

resource "kubernetes_namespace" "sample_cluster2" {
  provider = kubernetes.cluster2

  metadata {
    name = "sample"
    labels = {
      "istio.io/dataplane-mode"   = "ambient"
      "topology.istio.io/network" = var.cluster2_network
    }
  }

  depends_on = [
    helm_release.ztunnel_cluster2,
    null_resource.eastwest_gateway_cluster2,
  ]
}

# -----------------------------------------------------------------------------
# Helm Releases
# -----------------------------------------------------------------------------

resource "helm_release" "sample_app_cluster1" {
  provider = helm.cluster1

  name      = "istio-sample"
  namespace = "sample"
  chart     = "${path.module}/../helm/istio-sample-app"

  wait    = true
  timeout = 180

  set {
    name  = "helloworldVersion"
    value = "v1"
  }

  depends_on = [
    kubernetes_namespace.sample_cluster1,
  ]
}

resource "helm_release" "sample_app_cluster2" {
  provider = helm.cluster2

  name      = "istio-sample"
  namespace = "sample"
  chart     = "${path.module}/../helm/istio-sample-app"

  wait    = true
  timeout = 180

  set {
    name  = "helloworldVersion"
    value = "v2"
  }

  depends_on = [
    kubernetes_namespace.sample_cluster2,
  ]
}
