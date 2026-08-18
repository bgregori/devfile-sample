#!/usr/bin/env bash
set -euo pipefail

# Safely drain an OpenShift node with pre-flight checks and optional Vault-backed
# maintenance window tracking.

DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-300}"
VAULT_ADDR="${VAULT_ADDR:-}"
MAINTENANCE_PATH="${MAINTENANCE_PATH:-secret/cluster/maintenance}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <node-name> [--force] [--skip-vault]

Safely drain a node with pre-flight checks before cordoning.

Pre-flight checks:
  - Verifies the node exists and is currently schedulable
  - Checks for pods with local storage (PVCs on local volumes)
  - Warns if this would reduce available nodes below minimum threshold
  - Records a maintenance window in Vault (unless --skip-vault)

Options:
  --force       Skip confirmation prompts
  --skip-vault  Do not record maintenance in Vault

Environment:
  DRAIN_TIMEOUT      Seconds to wait for pod eviction (default: 300)
  VAULT_ADDR         Vault server for maintenance tracking
  MAINTENANCE_PATH   Vault KV path for maintenance records

Examples:
  $(basename "$0") worker-3.ocp.example.com
  $(basename "$0") worker-3.ocp.example.com --force
EOF
    exit 1
}

[[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

NODE="$1"
shift

FORCE=false
SKIP_VAULT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true ;;
        --skip-vault) SKIP_VAULT=true ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

echo "=== Pre-flight Checks for Node: $NODE ==="

if ! oc get node "$NODE" &>/dev/null; then
    echo "ERROR: Node '$NODE' not found in cluster" >&2
    exit 1
fi

schedulable=$(oc get node "$NODE" -o jsonpath='{.spec.unschedulable}')
if [[ "$schedulable" == "true" ]]; then
    echo "WARN: Node is already cordoned (unschedulable)" >&2
fi

echo ""
echo "--- Node Info ---"
oc get node "$NODE" -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:'.metadata.labels.node-role\.kubernetes\.io/*',VERSION:.status.nodeInfo.kubeletVersion --no-headers

echo ""
echo "--- Pod Count ---"
pod_count=$(oc get pods --all-namespaces --field-selector "spec.nodeName=$NODE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  $pod_count pod(s) running on this node"

daemonset_pods=$(oc get pods --all-namespaces --field-selector "spec.nodeName=$NODE" -o json | jq '[.items[] | select(.metadata.ownerReferences[]? .kind == "DaemonSet")] | length')
echo "  $daemonset_pods are DaemonSet pods (will not be evicted)"

echo ""
echo "--- Ready Node Count ---"
total_ready=$(oc get nodes -o json | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')
total_workers=$(oc get nodes -l 'node-role.kubernetes.io/worker' --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  $total_ready node(s) currently Ready, $total_workers worker(s)"

if [[ $total_workers -le 2 ]]; then
    echo "  WARNING: Draining this node will leave fewer than 2 workers!" >&2
fi

local_pvc_pods=$(oc get pods --all-namespaces --field-selector "spec.nodeName=$NODE" -o json | jq -r '
    .items[] |
    select(.spec.volumes[]? .persistentVolumeClaim) |
    "\(.metadata.namespace)/\(.metadata.name)"
' 2>/dev/null)

if [[ -n "$local_pvc_pods" ]]; then
    echo ""
    echo "--- Pods with PVC Mounts ---"
    echo "$local_pvc_pods" | sed 's/^/  /'
fi

if [[ "$FORCE" != "true" ]]; then
    echo ""
    read -rp "Proceed with drain of $NODE? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

if [[ "$SKIP_VAULT" != "true" && -n "$VAULT_ADDR" ]] && command -v vault &>/dev/null; then
    echo ""
    echo "Recording maintenance window in Vault..."
    vault kv put "$MAINTENANCE_PATH/$NODE" \
        node="$NODE" \
        action="drain" \
        started_by="$(oc whoami)" \
        started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        status="in-progress" 2>/dev/null || echo "  WARN: Could not write to Vault"
fi

echo ""
echo "Cordoning $NODE..."
oc adm cordon "$NODE"

echo "Draining $NODE (timeout: ${DRAIN_TIMEOUT}s)..."
oc adm drain "$NODE" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout="${DRAIN_TIMEOUT}s" \
    --force

if [[ "$SKIP_VAULT" != "true" && -n "$VAULT_ADDR" ]] && command -v vault &>/dev/null; then
    vault kv patch "$MAINTENANCE_PATH/$NODE" \
        status="drained" \
        drained_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" 2>/dev/null || true
fi

echo ""
echo "Node $NODE has been drained and cordoned."
echo "To return it to service: oc adm uncordon $NODE"
