#!/usr/bin/env bash
set -euo pipefail

# Audit an OpenShift namespace for resource quotas, limit ranges, stale resources,
# and security configuration.

usage() {
    cat <<EOF
Usage: $(basename "$0") <namespace> [namespace...]

Audits one or more OpenShift namespaces for common misconfigurations:
  - Missing ResourceQuotas or LimitRanges
  - Pods running as root or with privileged SCCs
  - Stale completed/failed jobs
  - Deployments with no resource requests/limits
  - Services with no matching endpoints

Examples:
  $(basename "$0") myapp-prod
  $(basename "$0") myapp-dev myapp-staging myapp-prod
EOF
    exit 1
}

[[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

audit_namespace() {
    local ns="$1"
    local findings=0

    echo -e "${CYAN}=== Namespace: $ns ===${NC}"

    if ! oc get namespace "$ns" &>/dev/null; then
        echo -e "  ${RED}Namespace does not exist${NC}"
        return 1
    fi

    echo "--- Governance ---"
    quota_count=$(oc get resourcequota -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$quota_count" -eq 0 ]]; then
        echo -e "  ${YELLOW}⚠ No ResourceQuota defined${NC}"
        findings=$((findings + 1))
    else
        echo -e "  ${GREEN}✓${NC} $quota_count ResourceQuota(s) in place"
    fi

    lr_count=$(oc get limitrange -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$lr_count" -eq 0 ]]; then
        echo -e "  ${YELLOW}⚠ No LimitRange defined${NC}"
        findings=$((findings + 1))
    else
        echo -e "  ${GREEN}✓${NC} $lr_count LimitRange(s) in place"
    fi

    netpol_count=$(oc get networkpolicy -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$netpol_count" -eq 0 ]]; then
        echo -e "  ${YELLOW}⚠ No NetworkPolicies — namespace traffic is unrestricted${NC}"
        findings=$((findings + 1))
    else
        echo -e "  ${GREEN}✓${NC} $netpol_count NetworkPolicy(ies)"
    fi

    echo ""
    echo "--- Security ---"
    privileged_pods=$(oc get pods -n "$ns" -o json | jq -r '
        .items[] |
        .metadata.name as $pod |
        .spec.containers[] |
        select(.securityContext.privileged == true or .securityContext.runAsUser == 0) |
        $pod
    ' 2>/dev/null | sort -u)

    if [[ -z "$privileged_pods" ]]; then
        echo -e "  ${GREEN}✓${NC} No privileged or root containers"
    else
        while IFS= read -r pod; do
            echo -e "  ${RED}✗ Privileged/root container: $pod${NC}"
            findings=$((findings + 1))
        done <<<"$privileged_pods"
    fi

    echo ""
    echo "--- Resource Requests ---"
    no_resources=$(oc get pods -n "$ns" -o json | jq -r '
        .items[] |
        select(.status.phase == "Running") |
        .metadata.name as $pod |
        .spec.containers[] |
        select(.resources.requests == null or .resources.limits == null) |
        "\($pod)/\(.name)"
    ' 2>/dev/null)

    if [[ -z "$no_resources" ]]; then
        echo -e "  ${GREEN}✓${NC} All running containers have resource requests and limits"
    else
        count=0
        while IFS= read -r entry; do
            echo -e "  ${YELLOW}⚠ Missing requests/limits: $entry${NC}"
            count=$((count + 1))
            findings=$((findings + 1))
        done <<<"$no_resources"
    fi

    echo ""
    echo "--- Stale Resources ---"
    stale_jobs=$(oc get jobs -n "$ns" -o json | jq -r '
        .items[] |
        select(.status.succeeded == 1 or .status.failed >= 1) |
        "\(.metadata.name) (\(if .status.succeeded == 1 then "Complete" else "Failed" end))"
    ' 2>/dev/null)

    if [[ -z "$stale_jobs" ]]; then
        echo -e "  ${GREEN}✓${NC} No completed/failed jobs lingering"
    else
        count=0
        while IFS= read -r job; do
            echo -e "  ${YELLOW}⚠ Stale job: $job${NC}"
            count=$((count + 1))
        done <<<"$stale_jobs"
        echo "    Run: oc delete jobs -n $ns --field-selector status.successful=1"
        findings=$((findings + count))
    fi

    echo ""
    echo "--- Endpoints ---"
    services_no_ep=$(oc get endpoints -n "$ns" -o json | jq -r '
        .items[] |
        select((.subsets // []) | length == 0) |
        .metadata.name
    ' 2>/dev/null)

    if [[ -z "$services_no_ep" ]]; then
        echo -e "  ${GREEN}✓${NC} All services have endpoints"
    else
        while IFS= read -r svc; do
            echo -e "  ${YELLOW}⚠ Service with no endpoints: $svc${NC}"
            findings=$((findings + 1))
        done <<<"$services_no_ep"
    fi

    echo ""
    if [[ $findings -eq 0 ]]; then
        echo -e "${GREEN}No issues found in $ns${NC}"
    else
        echo -e "${YELLOW}$findings finding(s) in $ns${NC}"
    fi
    echo ""
    return 0
}

total_findings=0
for ns in "$@"; do
    audit_namespace "$ns"
done
