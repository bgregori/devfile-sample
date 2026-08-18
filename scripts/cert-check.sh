#!/usr/bin/env bash
set -euo pipefail

# Check TLS certificate expiration across OpenShift routes and secrets.

WARN_DAYS="${WARN_DAYS:-30}"
CRIT_DAYS="${CRIT_DAYS:-7}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [namespace]

Scans TLS certificates in OpenShift routes and secrets for upcoming expiration.

Arguments:
  namespace    Specific namespace to check (default: all namespaces)

Environment:
  WARN_DAYS    Days threshold for warning (default: 30)
  CRIT_DAYS    Days threshold for critical (default: 7)

Examples:
  $(basename "$0")
  $(basename "$0") myapp-prod
  WARN_DAYS=60 $(basename "$0")
EOF
    exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

NAMESPACE="${1:-}"
NS_FLAG="-A"
[[ -n "$NAMESPACE" ]] && NS_FLAG="-n $NAMESPACE"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

now=$(date +%s)
warn_threshold=$((now + WARN_DAYS * 86400))
crit_threshold=$((now + CRIT_DAYS * 86400))

total=0
warnings=0
criticals=0
expired=0

echo "=== TLS Certificate Expiration Check ==="
echo "Warning threshold:  ${WARN_DAYS} days"
echo "Critical threshold: ${CRIT_DAYS} days"
echo ""

echo "--- Route Certificates ---"
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    route_ns=$(echo "$line" | awk '{print $1}')
    route_name=$(echo "$line" | awk '{print $2}')

    cert_pem=$(oc get route "$route_name" -n "$route_ns" -o jsonpath='{.spec.tls.certificate}' 2>/dev/null)
    [[ -z "$cert_pem" ]] && continue

    expiry_date=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -z "$expiry_date" ]] && continue

    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null || continue)
    days_left=$(( (expiry_epoch - now) / 86400 ))
    ((total++))

    if [[ $expiry_epoch -lt $now ]]; then
        echo -e "  ${RED}EXPIRED${NC}  route/$route_ns/$route_name (expired $((-days_left)) days ago)"
        ((expired++))
    elif [[ $expiry_epoch -lt $crit_threshold ]]; then
        echo -e "  ${RED}CRITICAL${NC} route/$route_ns/$route_name (${days_left} days remaining)"
        ((criticals++))
    elif [[ $expiry_epoch -lt $warn_threshold ]]; then
        echo -e "  ${YELLOW}WARNING${NC}  route/$route_ns/$route_name (${days_left} days remaining)"
        ((warnings++))
    fi
# shellcheck disable=SC2086
done < <(oc get routes $NS_FLAG --no-headers 2>/dev/null | awk '{print $1, $2}')

echo ""
echo "--- Secret Certificates ---"
# shellcheck disable=SC2086
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    sec_ns=$(echo "$line" | awk '{print $1}')
    sec_name=$(echo "$line" | awk '{print $2}')

    cert_b64=$(oc get secret "$sec_name" -n "$sec_ns" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
    [[ -z "$cert_b64" ]] && continue

    expiry_date=$(echo "$cert_b64" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -z "$expiry_date" ]] && continue

    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null || continue)
    days_left=$(( (expiry_epoch - now) / 86400 ))
    ((total++))

    if [[ $expiry_epoch -lt $now ]]; then
        echo -e "  ${RED}EXPIRED${NC}  secret/$sec_ns/$sec_name (expired $((-days_left)) days ago)"
        ((expired++))
    elif [[ $expiry_epoch -lt $crit_threshold ]]; then
        echo -e "  ${RED}CRITICAL${NC} secret/$sec_ns/$sec_name (${days_left} days remaining)"
        ((criticals++))
    elif [[ $expiry_epoch -lt $warn_threshold ]]; then
        echo -e "  ${YELLOW}WARNING${NC}  secret/$sec_ns/$sec_name (${days_left} days remaining)"
        ((warnings++))
    fi
done < <(oc get secrets $NS_FLAG --field-selector type=kubernetes.io/tls --no-headers 2>/dev/null | awk '{print $1, $2}')

echo ""
echo "==========================="
echo "Scanned: $total certificate(s)"
echo -e "Expired:  ${expired}"
echo -e "Critical: ${criticals}"
echo -e "Warning:  ${warnings}"

if [[ $expired -gt 0 || $criticals -gt 0 ]]; then
    exit 2
elif [[ $warnings -gt 0 ]]; then
    exit 1
fi
exit 0
