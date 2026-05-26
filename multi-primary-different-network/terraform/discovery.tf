# =============================================================================
# External Service Discovery — cluster3
# =============================================================================
# Deploys to the dedicated discovery cluster:
#   1. discovery namespace
#   2. Valkey standalone (single-AZ KV store + pub/sub)
#   3. xds-gateway TLS secret (cert signed by shared root CA)
#   4. remote-kubeconfigs secret (cluster1 + cluster2 kubeconfigs)
#   5. Docker build + kind load for endpoint-controller and xds-gateway images
#   6. Kubernetes manifests for endpoint-controller and xds-gateway
# =============================================================================

locals {
  discovery_dir  = abspath("${path.module}/../discovery")
  controller_dir = abspath("${path.module}/../discovery/endpoint-controller")
  gateway_dir    = abspath("${path.module}/../discovery/xds-gateway")
  certs_dir      = abspath("${path.module}/../certs")
}

# -----------------------------------------------------------------------------
# 1. discovery namespace on cluster3
# -----------------------------------------------------------------------------

resource "kubernetes_namespace" "discovery" {
  provider = kubernetes.cluster3

  metadata {
    name = "discovery"
  }

  depends_on = [kind_cluster.cluster3]
}

# Using null_resource + helm CLI because Terraform Helm provider v2.17 has
# an OCI compatibility issue with Bitnami charts (invalid_reference error).
# The helm CLI works correctly. This is idempotent.
resource "null_resource" "valkey_cluster3" {
  depends_on = [
    kubernetes_namespace.discovery,
    null_resource.cluster3_connect_network,
  ]

  triggers = {
    namespace  = "discovery"
    cluster_id = kind_cluster.cluster3.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
      if helm status valkey --kube-context kind-${var.cluster3_name} --namespace discovery &>/dev/null; then
        echo "    Valkey already installed, skipping."
      else
        echo "==> Installing Valkey into cluster3..."
        helm repo add bitnami https://charts.bitnami.com/bitnami --force-update 2>/dev/null
        helm install valkey bitnami/valkey \
          --kube-context kind-${var.cluster3_name} \
          --namespace discovery \
          --version 5.4.10 \
          --set architecture=standalone \
          --set auth.enabled=false \
          --set persistence.enabled=false \
          --set "primary.resources.requests.memory=64Mi" \
          --wait --timeout 180s
        echo "    Valkey installed."
      fi
    EOT
  }
}


# -----------------------------------------------------------------------------
# 3. xds-gateway TLS secret — cert signed by the shared root CA
#    Required before deploying xds-gateway pod.
# -----------------------------------------------------------------------------

resource "null_resource" "xds_gateway_cert" {
  depends_on = [null_resource.cluster3_connect_network]

  triggers = {
    cert_exists = fileexists("${local.certs_dir}/xds-gateway/tls.crt") ? "yes" : "no"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      CERT_DIR="${local.certs_dir}/xds-gateway"
      ROOT_CERT="${local.certs_dir}/root-cert.pem"
      ROOT_KEY="${local.certs_dir}/root-key.pem"
      if [ ! -f "$CERT_DIR/tls.crt" ]; then
        echo "==> Generating xds-gateway TLS cert..."
        mkdir -p "$CERT_DIR"
        openssl genrsa -out "$CERT_DIR/tls.key" 4096 2>/dev/null
        openssl req -new -key "$CERT_DIR/tls.key" \
          -subj "/O=Istio/CN=xds-gateway" \
          -out "$CERT_DIR/tls.csr" 2>/dev/null
        openssl x509 -req \
          -in "$CERT_DIR/tls.csr" \
          -CA "$ROOT_CERT" \
          -CAkey "$ROOT_KEY" \
          -CAcreateserial \
          -out "$CERT_DIR/tls.crt" \
          -days 730 \
          -extfile <(printf "subjectAltName=IP:10.90.0.2,DNS:xds-gateway.discovery.svc.cluster.local,DNS:xds-gateway.discovery.svc\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth") \
          2>/dev/null
        rm -f "$CERT_DIR/tls.csr"
        echo "    xds-gateway cert created (SAN: 10.90.0.2)"
      else
        echo "    xds-gateway cert already exists, skipping."
      fi
    EOT
  }
}

resource "kubernetes_secret" "xds_gateway_tls" {
  provider = kubernetes.cluster3

  metadata {
    name      = "xds-gateway-tls"
    namespace = "discovery"
  }

  data = {
    "tls.crt" = file("${local.certs_dir}/xds-gateway/tls.crt")
    "tls.key" = file("${local.certs_dir}/xds-gateway/tls.key")
  }

  type = "kubernetes.io/tls"

  depends_on = [
    kubernetes_namespace.discovery,
    null_resource.xds_gateway_cert,
  ]
}

# -----------------------------------------------------------------------------
# 4. remote-kubeconfigs secret — gives endpoint-controller access to cluster1/2
#    Uses the kubeconfig that kind wrote to ~/.kube/config (host-accessible URL).
# -----------------------------------------------------------------------------

resource "kubernetes_secret" "remote_kubeconfigs" {
  provider = kubernetes.cluster3

  metadata {
    name      = "remote-kubeconfigs"
    namespace = "discovery"
  }

  data = {
    # Use the container-name-based server URL so that the controller (running
    # inside kind's Docker network) can reach the other clusters' API servers.
    "cluster1" = <<-EOT
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

    "cluster2" = <<-EOT
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
    kubernetes_namespace.discovery,
    kind_cluster.cluster1,
    kind_cluster.cluster2,
  ]
}

# -----------------------------------------------------------------------------
# 5. Docker build + kind load for endpoint-controller
# -----------------------------------------------------------------------------

resource "null_resource" "build_endpoint_controller" {
  depends_on = [kind_cluster.cluster3]

  triggers = {
    # Rebuild when any source files change
    source_hash = sha256(join("", [
      for f in fileset(local.controller_dir, "**/*.go") : filesha256("${local.controller_dir}/${f}")
    ]))
    dockerfile_hash = filesha256("${local.controller_dir}/Dockerfile")
    gomod_hash      = filesha256("${local.controller_dir}/go.mod")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

      echo "==> go mod tidy: endpoint-controller"
      cd "${local.controller_dir}" && go mod tidy

      echo "==> Building endpoint-controller image..."
      docker build -t endpoint-controller:latest "${local.controller_dir}"

      echo "==> Loading endpoint-controller image into kind cluster3..."
      kind load docker-image endpoint-controller:latest --name ${var.cluster3_name}
      echo "    Done."
    EOT
  }
}

# -----------------------------------------------------------------------------
# 6. Docker build + kind load for xds-gateway
# -----------------------------------------------------------------------------

resource "null_resource" "build_xds_gateway" {
  depends_on = [kind_cluster.cluster3, null_resource.xds_gateway_cert]

  triggers = {
    # Rebuild when any source files change
    source_hash = sha256(join("", [
      for f in fileset(local.gateway_dir, "**/*.go") : filesha256("${local.gateway_dir}/${f}")
    ]))
    dockerfile_hash = filesha256("${local.gateway_dir}/Dockerfile")
    gomod_hash      = filesha256("${local.gateway_dir}/go.mod")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

      echo "==> go mod tidy: xds-gateway"
      cd "${local.gateway_dir}" && go mod tidy

      echo "==> Building xds-gateway image..."
      docker build -t xds-gateway:latest "${local.gateway_dir}"

      echo "==> Loading xds-gateway image into kind cluster3..."
      kind load docker-image xds-gateway:latest --name ${var.cluster3_name}
      echo "    Done."
    EOT
  }
}

# -----------------------------------------------------------------------------
# 7. Deploy discovery services to cluster3
# -----------------------------------------------------------------------------

# Apply RBAC, Deployments, and Services in order
resource "null_resource" "deploy_discovery_services" {
  depends_on = [
    kubernetes_secret.xds_gateway_tls,
    kubernetes_secret.remote_kubeconfigs,
    null_resource.valkey_cluster3,
    null_resource.build_endpoint_controller,
    null_resource.build_xds_gateway,
    null_resource.metallb_config_cluster3,
  ]

  triggers = {
    controller_hash = null_resource.build_endpoint_controller.id
    gateway_hash    = null_resource.build_xds_gateway.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      CTX="kind-${var.cluster3_name}"

      echo "==> Applying endpoint-controller RBAC..."
      kubectl --context "$CTX" apply -f "${local.controller_dir}/k8s/rbac.yaml"

      echo "==> Applying endpoint-controller Deployment..."
      kubectl --context "$CTX" apply -f "${local.controller_dir}/k8s/deployment.yaml"

      echo "==> Applying xds-gateway Deployment..."
      kubectl --context "$CTX" apply -f "${local.gateway_dir}/k8s/deployment.yaml"

      echo "==> Applying xds-gateway Service..."
      kubectl --context "$CTX" apply -f "${local.gateway_dir}/k8s/service.yaml"

      echo "==> Waiting for xds-gateway rollout..."
      kubectl --context "$CTX" rollout status deployment/xds-gateway -n discovery --timeout=120s

      echo "==> Waiting for endpoint-controller rollout..."
      kubectl --context "$CTX" rollout status deployment/endpoint-controller -n discovery --timeout=120s

      echo "    Discovery services deployed successfully."
    EOT
  }
}

# Sentinel resource that ztunnel Helm releases depend on.
# Ensures the gateway is live and has its MetalLB IP before ztunnel starts.
resource "null_resource" "discovery_ready" {
  depends_on = [null_resource.deploy_discovery_services]

  triggers = {
    gateway_hash = null_resource.build_xds_gateway.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      CTX="kind-${var.cluster3_name}"
      echo "==> Verifying xds-gateway LoadBalancer IP..."
      for i in $(seq 1 30); do
        LB_IP=$(kubectl --context "$CTX" get svc xds-gateway -n discovery \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ "$LB_IP" = "10.90.0.2" ]; then
          echo "    xds-gateway reachable at 10.90.0.2:15012"
          exit 0
        fi
        echo "    Waiting for MetalLB to assign 10.90.0.2... ($i/30)"
        sleep 5
      done
      echo "ERROR: xds-gateway did not get IP 10.90.0.2 in time"
      exit 1
    EOT
  }
}
