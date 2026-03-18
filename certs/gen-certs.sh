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

echo ""
echo "==> Done! Certificate structure:"
find "${CERTS_DIR}" -name "*.pem" | sort | sed "s|${CERTS_DIR}/|  |"
