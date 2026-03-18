# =============================================================================
# MetalLB Installation and Configuration for Both Clusters
# =============================================================================
# MetalLB is deployed via Helm, then configured with IPAddressPool and
# L2Advertisement CRDs via kubectl apply (deferred to apply time).
# =============================================================================

# -----------------------------------------------------------------------------
# Cluster 1 — MetalLB
# -----------------------------------------------------------------------------

resource "helm_release" "metallb_cluster1" {
  provider = helm.cluster1

  name             = "metallb"
  namespace        = "metallb-system"
  create_namespace = true
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = var.metallb_chart_version

  wait          = true
  wait_for_jobs = true
  timeout       = 300

  depends_on = [
    null_resource.cluster1_connect_network,
  ]
}

# Apply MetalLB CRDs via kubectl — this defers cluster communication to apply time
resource "null_resource" "metallb_config_cluster1" {
  depends_on = [helm_release.metallb_cluster1]

  triggers = {
    ip_range   = var.cluster1_metallb_ip_range
    cluster_id = kind_cluster.cluster1.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context kind-${var.cluster1_name} apply -f - <<EOF
      apiVersion: metallb.io/v1beta1
      kind: IPAddressPool
      metadata:
        name: default-pool
        namespace: metallb-system
      spec:
        addresses:
          - ${var.cluster1_metallb_ip_range}
      ---
      apiVersion: metallb.io/v1beta1
      kind: L2Advertisement
      metadata:
        name: default-l2
        namespace: metallb-system
      spec:
        ipAddressPools:
          - default-pool
      EOF
    EOT
  }
}

# -----------------------------------------------------------------------------
# Cluster 2 — MetalLB
# -----------------------------------------------------------------------------

resource "helm_release" "metallb_cluster2" {
  provider = helm.cluster2

  name             = "metallb"
  namespace        = "metallb-system"
  create_namespace = true
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = var.metallb_chart_version

  wait          = true
  wait_for_jobs = true
  timeout       = 300

  depends_on = [
    null_resource.cluster2_connect_network,
  ]
}

resource "null_resource" "metallb_config_cluster2" {
  depends_on = [helm_release.metallb_cluster2]

  triggers = {
    ip_range   = var.cluster2_metallb_ip_range
    cluster_id = kind_cluster.cluster2.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context kind-${var.cluster2_name} apply -f - <<EOF
      apiVersion: metallb.io/v1beta1
      kind: IPAddressPool
      metadata:
        name: default-pool
        namespace: metallb-system
      spec:
        addresses:
          - ${var.cluster2_metallb_ip_range}
      ---
      apiVersion: metallb.io/v1beta1
      kind: L2Advertisement
      metadata:
        name: default-l2
        namespace: metallb-system
      spec:
        ipAddressPools:
          - default-pool
      EOF
    EOT
  }
}
