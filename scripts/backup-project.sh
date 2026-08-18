#!/usr/bin/env bash
set -euo pipefail

# Export all key resources from an OpenShift namespace to YAML for backup/migration.

BACKUP_DIR="${BACKUP_DIR:-./backups}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <namespace> [--output-dir DIR]

Exports all major resources from a namespace as YAML files for backup or migration.

Exported resources:
  - Deployments, StatefulSets, DaemonSets
  - Services, Routes, Ingresses
  - ConfigMaps, Secrets
  - PVCs, ServiceAccounts, RoleBindings
  - NetworkPolicies, LimitRanges, ResourceQuotas
  - CronJobs, Jobs

Options:
  --output-dir DIR  Output directory (default: ./backups)

Examples:
  $(basename "$0") myapp-prod
  $(basename "$0") myapp-prod --output-dir /tmp/backups
EOF
    exit 1
}

[[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

NAMESPACE="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) BACKUP_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    echo "ERROR: Namespace '$NAMESPACE' not found" >&2
    exit 1
fi

timestamp=$(date +"%Y%m%d-%H%M%S")
output="${BACKUP_DIR}/${NAMESPACE}/${timestamp}"
mkdir -p "$output"

RESOURCE_TYPES=(
    deployments
    statefulsets
    daemonsets
    services
    routes
    ingresses
    configmaps
    secrets
    persistentvolumeclaims
    serviceaccounts
    rolebindings
    networkpolicies
    limitranges
    resourcequotas
    cronjobs
    jobs
)

echo "=== Backing up namespace: $NAMESPACE ==="
echo "Output: $output"
echo ""

total=0
for resource in "${RESOURCE_TYPES[@]}"; do
    items=$(oc get "$resource" -n "$NAMESPACE" -o name 2>/dev/null || true)
    if [[ -z "$items" ]]; then
        continue
    fi

    resource_dir="${output}/${resource}"
    mkdir -p "$resource_dir"

    count=0
    while IFS= read -r item; do
        name=$(basename "$item")
        oc get "$item" -n "$NAMESPACE" -o yaml | \
            sed '/^\s*resourceVersion:/d; /^\s*uid:/d; /^\s*creationTimestamp:/d; /^\s*generation:/d; /^\s*selfLink:/d' \
            > "${resource_dir}/${name}.yaml"
        count=$((count + 1))
    done <<<"$items"

    printf "  %-25s %d item(s)\n" "$resource" "$count"
    total=$((total + count))
done

echo ""
echo "Total: $total resource(s) backed up"

manifest="${output}/MANIFEST.txt"
{
    echo "Backup Manifest"
    echo "==============="
    echo "Namespace: $NAMESPACE"
    echo "Timestamp: $timestamp"
    echo "Backed up by: $(oc whoami 2>/dev/null || echo unknown)"
    echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo unknown)"
    echo ""
    echo "Contents:"
    find "$output" -name "*.yaml" | sort | sed "s|${output}/|  |"
} > "$manifest"

echo "Manifest written to: $manifest"
echo ""
echo "To restore: oc apply -f $output/<resource-type>/ -n <target-namespace>"
