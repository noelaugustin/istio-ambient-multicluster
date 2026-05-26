#!/usr/bin/env bash
# Generate root CA and per-cluster intermediate CAs for Istio multi-cluster trust.
# Usage: ./gen-certs.sh [certs_dir]
#
# Structure created:
#   <certs_dir>/
#   ├── root-cert.pem
#   ├── root-key.pem
#   ├── cluster1/
#   │   ├── ca-cert.pem
#   │   ├── ca-key.pem
#   │   ├── cert-chain.pem
#   │   └── root-cert.pem (copy)
#   └── cluster2/
#       ├── ca-cert.pem
#       ├── ca-key.pem
#       ├── cert-chain.pem
#       └── root-cert.pem (copy)

set -euo pipefail

CERTS_DIR="${1:-$(dirname "$0")}"
DAYS_ROOT=3650
DAYS_INTERMEDIATE=730
KEY_SIZE=4096

echo "==> Generating certs in: ${CERTS_DIR}"

mkdir -p "${CERTS_DIR}/cluster1" "${CERTS_DIR}/cluster2"

# --- Root CA ---
if [ ! -f "${CERTS_DIR}/root-key.pem" ]; then
  echo "==> Generating Root CA..."
  openssl req -newkey "rsa:${KEY_SIZE}" -nodes \
    -keyout "${CERTS_DIR}/root-key.pem" \
    -x509 -days "${DAYS_ROOT}" \
    -out "${CERTS_DIR}/root-cert.pem" \
    -subj "/O=Istio/CN=Root CA" \
    2>/dev/null
  echo "    Root CA created."
else
  echo "    Root CA already exists, skipping."
fi

# --- Per-cluster intermediate CAs ---
generate_intermediate() {
  local cluster_name="$1"
  local cluster_dir="${CERTS_DIR}/${cluster_name}"

  if [ ! -f "${cluster_dir}/ca-key.pem" ]; then
    echo "==> Generating intermediate CA for ${cluster_name}..."

    # Generate key + CSR
    openssl req -newkey "rsa:${KEY_SIZE}" -nodes \
      -keyout "${cluster_dir}/ca-key.pem" \
      -out "${cluster_dir}/ca-cert.csr" \
      -subj "/O=Istio/CN=Intermediate CA (${cluster_name})" \
      2>/dev/null

    # Create extensions config for CA signing
    cat > "${cluster_dir}/ca-ext.cnf" <<EOF
[v3_intermediate_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF

    # Sign with root CA
    openssl x509 -req \
      -in "${cluster_dir}/ca-cert.csr" \
      -CA "${CERTS_DIR}/root-cert.pem" \
      -CAkey "${CERTS_DIR}/root-key.pem" \
      -CAcreateserial \
      -out "${cluster_dir}/ca-cert.pem" \
      -days "${DAYS_INTERMEDIATE}" \
      -extfile "${cluster_dir}/ca-ext.cnf" \
      -extensions v3_intermediate_ca \
      2>/dev/null

    # cert-chain = intermediate + root
    cat "${cluster_dir}/ca-cert.pem" "${CERTS_DIR}/root-cert.pem" \
      > "${cluster_dir}/cert-chain.pem"

    # Copy root cert for the cacerts secret
    cp "${CERTS_DIR}/root-cert.pem" "${cluster_dir}/root-cert.pem"

    # Cleanup temp files
    rm -f "${cluster_dir}/ca-cert.csr" "${cluster_dir}/ca-ext.cnf"

    echo "    Intermediate CA for ${cluster_name} created."
  else
    echo "    Intermediate CA for ${cluster_name} already exists, skipping."
  fi
}

generate_intermediate "cluster1"
generate_intermediate "cluster2"

# --- xds-gateway TLS server cert ---
# Signed by the shared root CA so that ztunnel can verify it via the
# istiod-ca-cert ConfigMap (which contains root-cert.pem).
generate_xds_gateway_cert() {
  local gw_dir="${CERTS_DIR}/xds-gateway"

  if [ ! -f "${gw_dir}/tls.crt" ]; then
    echo "==> Generating xds-gateway TLS server cert..."
    mkdir -p "${gw_dir}"

    # Generate private key
    openssl genrsa -out "${gw_dir}/tls.key" "${KEY_SIZE}" 2>/dev/null

    # Generate CSR
    openssl req -new \
      -key "${gw_dir}/tls.key" \
      -subj "/O=Istio/CN=xds-gateway" \
      -out "${gw_dir}/tls.csr" \
      2>/dev/null

    # Sign with shared root CA — include IP SAN for fixed MetalLB IP
    openssl x509 -req \
      -in "${gw_dir}/tls.csr" \
      -CA "${CERTS_DIR}/root-cert.pem" \
      -CAkey "${CERTS_DIR}/root-key.pem" \
      -CAcreateserial \
      -out "${gw_dir}/tls.crt" \
      -days "${DAYS_INTERMEDIATE}" \
      -extfile <(printf "subjectAltName=IP:10.90.0.2,DNS:xds-gateway.discovery.svc.cluster.local,DNS:xds-gateway.discovery.svc\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth") \
      2>/dev/null

    rm -f "${gw_dir}/tls.csr"
    echo "    xds-gateway cert created (SAN: IP:10.90.0.2)"
  else
    echo "    xds-gateway cert already exists, skipping."
  fi
}

generate_xds_gateway_cert

echo ""
echo "==> Done! Certificate structure:"
find "${CERTS_DIR}" -name "*.pem" | sort | sed "s|${CERTS_DIR}/|  |"

