#!/usr/bin/env bash
set -euo pipefail

# Rotate credentials in Vault and restart dependent deployments in OpenShift.

VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR must be set}"
CREDENTIAL_LENGTH="${CREDENTIAL_LENGTH:-32}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <vault-path> <key> <namespace> <deployment,...>

Generates a new random credential, writes it to a Vault KV path, then triggers
a rollout restart on the specified OpenShift deployments.

Arguments:
  vault-path     Vault KV secret path (e.g. secret/data/myapp/db)
  key            Key within the secret to rotate (e.g. password)
  namespace      OpenShift namespace containing the deployments
  deployment     Comma-separated deployment names to restart

Environment:
  CREDENTIAL_LENGTH  Length of generated credential (default: 32)

Examples:
  $(basename "$0") secret/myapp/db password myapp-prod api-server,worker
  CREDENTIAL_LENGTH=64 $(basename "$0") secret/myapp/api api-key myapp-staging backend
EOF
    exit 1
}

[[ $# -lt 4 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

vault_path="$1"
key="$2"
namespace="$3"
IFS=',' read -ra deployments <<<"$4"

for cmd in vault oc openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found in PATH" >&2
        exit 1
    fi
done

echo "Rotating credential at $vault_path [$key]"

new_credential=$(openssl rand -base64 "$CREDENTIAL_LENGTH" | tr -d '\n')

existing=$(vault kv get -format=json "$vault_path" 2>/dev/null | jq -r '.data.data // .data' 2>/dev/null) || existing="{}"

updated=$(echo "$existing" | jq --arg k "$key" --arg v "$new_credential" '. + {($k): $v}')
echo "$updated" | vault kv put "$vault_path" -

echo "Vault secret updated."

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

for deploy in "${deployments[@]}"; do
    echo "Restarting deployment: $namespace/$deploy"
    oc annotate deployment "$deploy" -n "$namespace" \
        "credential-rotation/last-rotated=$timestamp" \
        --overwrite
    oc rollout restart deployment/"$deploy" -n "$namespace"
done

echo ""
echo "Waiting for rollouts to complete..."
for deploy in "${deployments[@]}"; do
    if oc rollout status deployment/"$deploy" -n "$namespace" --timeout=300s; then
        echo "  $deploy: ready"
    else
        echo "  $deploy: TIMEOUT — check manually" >&2
    fi
done

echo ""
echo "Rotation complete at $timestamp"
