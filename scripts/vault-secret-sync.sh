#!/usr/bin/env bash
set -euo pipefail

# Sync secrets from HashiCorp Vault into OpenShift namespaces as Kubernetes Secrets.
# Reads a mapping file that defines which Vault paths map to which namespace/secret-name pairs.

MAPPING_FILE="${1:-vault-secret-mappings.yaml}"
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR must be set}"
DRY_RUN="${DRY_RUN:-false}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [MAPPING_FILE]

Syncs secrets from Vault KV into OpenShift Secrets based on a YAML mapping file.

Mapping file format (one entry per line, '#' comments allowed):
  vault/path/to/secret  namespace  secret-name

Environment:
  VAULT_ADDR     Vault server address (required)
  VAULT_TOKEN    Vault token (or use vault login first)
  DRY_RUN        Set to 'true' to preview without applying

Examples:
  $(basename "$0") mappings.txt
  DRY_RUN=true $(basename "$0") mappings.txt
EOF
    exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

if ! command -v vault &>/dev/null; then
    echo "ERROR: vault CLI not found in PATH" >&2
    exit 1
fi

if ! command -v oc &>/dev/null; then
    echo "ERROR: oc CLI not found in PATH" >&2
    exit 1
fi

if [[ ! -f "$MAPPING_FILE" ]]; then
    echo "ERROR: Mapping file '$MAPPING_FILE' not found" >&2
    exit 1
fi

synced=0
failed=0

while IFS= read -r line; do
    line="${line%%#*}"
    [[ -z "${line// /}" ]] && continue

    read -r vault_path namespace secret_name <<<"$line"

    if [[ -z "$vault_path" || -z "$namespace" || -z "$secret_name" ]]; then
        echo "WARN: Skipping malformed line: $line" >&2
        continue
    fi

    echo "--- Syncing: $vault_path -> $namespace/$secret_name"

    secret_json=$(vault kv get -format=json "$vault_path" 2>&1) || {
        echo "  FAILED: Could not read $vault_path from Vault" >&2
        failed=$((failed + 1))
        continue
    }

    keys=$(echo "$secret_json" | jq -r '.data.data // .data | keys[]')
    literal_args=()
    while IFS= read -r key; do
        val=$(echo "$secret_json" | jq -r --arg k "$key" '.data.data // .data | .[$k]')
        literal_args+=("--from-literal=${key}=${val}")
    done <<<"$keys"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY RUN: would create/update secret '$secret_name' in '$namespace' with keys: $keys"
        synced=$((synced + 1))
        continue
    fi

    oc create secret generic "$secret_name" \
        -n "$namespace" \
        "${literal_args[@]}" \
        --dry-run=client -o yaml | oc apply -f - >/dev/null

    oc label secret "$secret_name" -n "$namespace" \
        managed-by=vault-secret-sync \
        vault-path="${vault_path//\//_}" \
        --overwrite >/dev/null

    echo "  OK: synced ${#literal_args[@]} key(s)"
    synced=$((synced + 1))

done <"$MAPPING_FILE"

echo ""
echo "Sync complete: $synced succeeded, $failed failed"
[[ $failed -gt 0 ]] && exit 1
exit 0
