#!/usr/bin/env bash
set -euo pipefail

# Issue TLS certificates from Vault's PKI secrets engine and optionally store
# them as OpenShift TLS secrets or apply them to routes.

VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR must be set}"
PKI_ROLE="${PKI_ROLE:-server}"
PKI_MOUNT="${PKI_MOUNT:-pki}"
TTL="${TTL:-720h}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <common-name> [options]

Issues a TLS certificate from Vault PKI and optionally creates an OpenShift
TLS secret or updates a route.

Arguments:
  common-name              The CN for the certificate (e.g. myapp.example.com)

Options:
  --alt-names NAMES        Comma-separated SANs
  --namespace NS           OpenShift namespace for secret/route
  --secret-name NAME       Create a TLS secret with this name
  --route-name NAME        Apply cert to this route
  --output-dir DIR         Write cert files to this directory
  --ttl DURATION           Certificate TTL (default: 720h)
  --pki-role ROLE          Vault PKI role (default: server)
  --pki-mount MOUNT        Vault PKI mount point (default: pki)

Examples:
  $(basename "$0") myapp.example.com --secret-name myapp-tls --namespace myapp-prod
  $(basename "$0") api.example.com --alt-names "api-v2.example.com" --output-dir ./certs
  $(basename "$0") internal.svc --route-name api-route --namespace myapp-prod
EOF
    exit 1
}

[[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

COMMON_NAME="$1"
shift

ALT_NAMES=""
NAMESPACE=""
SECRET_NAME=""
ROUTE_NAME=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --alt-names)    ALT_NAMES="$2"; shift 2 ;;
        --namespace)    NAMESPACE="$2"; shift 2 ;;
        --secret-name)  SECRET_NAME="$2"; shift 2 ;;
        --route-name)   ROUTE_NAME="$2"; shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        --ttl)          TTL="$2"; shift 2 ;;
        --pki-role)     PKI_ROLE="$2"; shift 2 ;;
        --pki-mount)    PKI_MOUNT="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

for cmd in vault jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found in PATH" >&2
        exit 1
    fi
done

echo "Issuing certificate for: $COMMON_NAME"
echo "  PKI mount: $PKI_MOUNT, role: $PKI_ROLE, TTL: $TTL"

issue_args=("common_name=$COMMON_NAME" "ttl=$TTL")
[[ -n "$ALT_NAMES" ]] && issue_args+=("alt_names=$ALT_NAMES")

cert_json=$(vault write -format=json "${PKI_MOUNT}/issue/${PKI_ROLE}" "${issue_args[@]}")

cert=$(echo "$cert_json" | jq -r '.data.certificate')
key=$(echo "$cert_json" | jq -r '.data.private_key')
ca=$(echo "$cert_json" | jq -r '.data.issuing_ca')
serial=$(echo "$cert_json" | jq -r '.data.serial_number')
expiration=$(echo "$cert_json" | jq -r '.data.expiration')

echo "  Serial: $serial"
echo "  Expires: $(date -d "@$expiration" 2>/dev/null || date -r "$expiration" 2>/dev/null || echo "$expiration")"

if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"
    echo "$cert" > "${OUTPUT_DIR}/${COMMON_NAME}.crt"
    echo "$key" > "${OUTPUT_DIR}/${COMMON_NAME}.key"
    echo "$ca" > "${OUTPUT_DIR}/${COMMON_NAME}-ca.crt"
    chmod 600 "${OUTPUT_DIR}/${COMMON_NAME}.key"
    echo "  Files written to: $OUTPUT_DIR"
fi

if [[ -n "$SECRET_NAME" ]]; then
    [[ -z "$NAMESPACE" ]] && { echo "ERROR: --namespace required with --secret-name" >&2; exit 1; }

    oc create secret tls "$SECRET_NAME" \
        -n "$NAMESPACE" \
        --cert=<(echo "$cert") \
        --key=<(echo "$key") \
        --dry-run=client -o yaml | oc apply -f -

    oc label secret "$SECRET_NAME" -n "$NAMESPACE" \
        managed-by=vault-pki \
        vault-serial="$serial" \
        --overwrite

    echo "  Secret '$SECRET_NAME' created/updated in '$NAMESPACE'"
fi

if [[ -n "$ROUTE_NAME" ]]; then
    [[ -z "$NAMESPACE" ]] && { echo "ERROR: --namespace required with --route-name" >&2; exit 1; }

    oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type=merge -p "$(cat <<PATCH
{
  "spec": {
    "tls": {
      "certificate": $(echo "$cert" | jq -Rs .),
      "key": $(echo "$key" | jq -Rs .),
      "caCertificate": $(echo "$ca" | jq -Rs .)
    }
  }
}
PATCH
)"
    echo "  Route '$ROUTE_NAME' updated in '$NAMESPACE'"
fi

echo ""
echo "Certificate issued successfully."
