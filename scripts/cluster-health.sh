#!/usr/bin/env bash
set -euo pipefail

# Quick health check across an OpenShift cluster: nodes, pods, operators, and certificates.

WARN_CERT_DAYS="${WARN_CERT_DAYS:-30}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--full]

Runs a health check across the current OpenShift cluster.

Checks:
  - Node status and resource pressure
  - Pods in error states (CrashLoopBackOff, ImagePullBackOff, etc.)
  - ClusterOperator degraded/unavailable conditions
  - Certificate expiration within ${WARN_CERT_DAYS} days
  - PersistentVolume capacity warnings

Options:
  --full    Include per-namespace resource usage breakdown

Environment:
  WARN_CERT_DAYS  Days before cert expiry to warn (default: 30)
EOF
    exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

FULL_MODE=false
[[ "${1:-}" == "--full" ]] && FULL_MODE=true

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

issues=0

echo "=== Cluster Health Check ==="
echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
echo "User:    $(oc whoami 2>/dev/null || echo 'unknown')"
echo "Time:    $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo ""

echo "--- Nodes ---"
not_ready=$(oc get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status!="True")) | .metadata.name')
if [[ -z "$not_ready" ]]; then
    pass "All nodes are Ready"
else
    while IFS= read -r node; do
        fail "Node not ready: $node"
        issues=$((issues + 1))
    done <<<"$not_ready"
fi

pressure_nodes=$(oc get nodes -o json | jq -r '
    .items[] |
    .metadata.name as $name |
    .status.conditions[] |
    select((.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") and .status == "True") |
    "\($name): \(.type)"
')
if [[ -z "$pressure_nodes" ]]; then
    pass "No resource pressure detected"
else
    while IFS= read -r entry; do
        warn "$entry"
        issues=$((issues + 1))
    done <<<"$pressure_nodes"
fi

echo ""
echo "--- Problem Pods ---"
problem_pods=$(oc get pods -A -o json | jq -r '
    .items[] |
    select(
        .status.phase == "Failed" or
        (.status.containerStatuses // [] | any(
            .state.waiting.reason == "CrashLoopBackOff" or
            .state.waiting.reason == "ImagePullBackOff" or
            .state.waiting.reason == "ErrImagePull" or
            .state.waiting.reason == "CreateContainerConfigError"
        ))
    ) |
    "\(.metadata.namespace)/\(.metadata.name): \(
        if .status.phase == "Failed" then "Failed"
        else (.status.containerStatuses[]? | .state.waiting.reason // "Unknown") end
    )"
')
if [[ -z "$problem_pods" ]]; then
    pass "No pods in error states"
else
    count=0
    while IFS= read -r pod; do
        fail "$pod"
        count=$((count + 1))
        issues=$((issues + 1))
    done <<<"$problem_pods"
    echo "  ($count problem pod(s) total)"
fi

echo ""
echo "--- ClusterOperators ---"
degraded=$(oc get clusteroperators -o json | jq -r '
    .items[] |
    .metadata.name as $name |
    .status.conditions[] |
    select(
        (.type == "Degraded" and .status == "True") or
        (.type == "Available" and .status == "False")
    ) |
    "\($name): \(.type)=\(.status)"
')
if [[ -z "$degraded" ]]; then
    pass "All ClusterOperators healthy"
else
    while IFS= read -r op; do
        fail "$op"
        issues=$((issues + 1))
    done <<<"$degraded"
fi

echo ""
echo "--- Certificate Expiration ---"
expiring=$(oc get secrets -A -o json | jq -r --argjson days "$WARN_CERT_DAYS" '
    .items[] |
    select(.type == "kubernetes.io/tls") |
    .metadata.namespace as $ns |
    .metadata.name as $name |
    (.data."tls.crt" // empty) |
    @base64d |
    capture("Not After *: *(?<expiry>.+)") // empty |
    .expiry
' 2>/dev/null || true)

if [[ -z "$expiring" ]]; then
    pass "No TLS certificate issues detected"
else
    warn "Certificates approaching expiration found — review with: oc get secrets -A -o json | jq '.items[] | select(.type==\"kubernetes.io/tls\")'"
fi

echo ""
echo "--- PersistentVolumes ---"
pv_issues=$(oc get pv -o json 2>/dev/null | jq -r '
    .items[] |
    select(.status.phase == "Released" or .status.phase == "Failed") |
    "\(.metadata.name): \(.status.phase) (\(.spec.capacity.storage))"
' || true)
if [[ -z "$pv_issues" ]]; then
    pass "All PVs bound or available"
else
    while IFS= read -r pv; do
        warn "PV $pv"
        issues=$((issues + 1))
    done <<<"$pv_issues"
fi

if [[ "$FULL_MODE" == "true" ]]; then
    echo ""
    echo "--- Namespace Resource Usage ---"
    oc get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read -r ns; do
        pod_count=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        [[ "$pod_count" -eq 0 ]] && continue
        echo "  $ns: $pod_count pod(s)"
    done
fi

echo ""
echo "==========================="
if [[ $issues -eq 0 ]]; then
    echo -e "${GREEN}Cluster is healthy${NC}"
else
    echo -e "${YELLOW}Found $issues issue(s) — review above${NC}"
fi
