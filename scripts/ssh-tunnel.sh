#!/usr/bin/env bash
set -euo pipefail

# Establish SSH tunnels to backend services through a bastion host using
# Vault-signed ephemeral SSH certificates. Authenticates to Vault via GitHub,
# generates a temporary key pair, gets it signed by Vault's ssh-client-signer,
# and uses the short-lived certificate for all tunnels. Keys are destroyed on exit.

VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_AUTH_GITHUB_TOKEN="${VAULT_AUTH_GITHUB_TOKEN:-}"
VAULT_SSH_MOUNT="${VAULT_SSH_MOUNT:-ssh-client-signer}"
VAULT_SSH_ROLE="${VAULT_SSH_ROLE:-dev}"
SSH_KEY="${SSH_KEY:-}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <tunnel-config-file>
       $(basename "$0") <bastion> <local-port>:<remote-host>:<remote-port> [...]

Establishes SSH tunnels through a bastion host using Vault-signed ephemeral
SSH certificates. Generates a temporary key pair, authenticates to Vault via
GitHub, requests a signed certificate, and uses it for all tunnels. Keys are
destroyed when tunnels are closed.

Config file format (one tunnel per line):
  bastion-host  local-port:remote-host:remote-port  # optional comment

Environment:
  VAULT_ADDR                 Vault server address (required)
  VAULT_AUTH_GITHUB_TOKEN    GitHub PAT with read:org scope (required)
  VAULT_TOKEN                Skip GitHub auth if already set
  VAULT_SSH_MOUNT            Vault SSH engine mount (default: ssh-client-signer)
  VAULT_SSH_ROLE             Vault SSH signing role (default: dev)
  SSH_KEY                    Use a static key instead of Vault signing
  SSH_USER                   Override SSH username (default: from Vault role)
  SSH_OPTS                   Additional SSH options

Examples:
  $(basename "$0") tunnels.conf
  $(basename "$0") bastion.example.com 5432:db.internal:5432 6379:redis.internal:6379
  SSH_KEY=~/.ssh/id_rsa $(basename "$0") bastion.example.com 5432:db.internal:5432
EOF
    exit 1
}

[[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

EPHEMERAL_DIR=""
declare -a tunnel_pids=()

cleanup() {
    echo ""
    echo "Closing tunnels..."
    for pid in "${tunnel_pids[@]}"; do
        kill "$pid" 2>/dev/null && echo "  Stopped tunnel (PID $pid)"
    done
    if [[ -n "$EPHEMERAL_DIR" && -d "$EPHEMERAL_DIR" ]]; then
        rm -rf "$EPHEMERAL_DIR"
        echo "  Ephemeral keys destroyed"
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

obtain_key() {
    if [[ -n "$SSH_KEY" ]]; then
        echo "Using static key: $SSH_KEY"
        if [[ ! -f "$SSH_KEY" ]]; then
            echo "ERROR: SSH key '$SSH_KEY' not found" >&2
            exit 1
        fi
        return
    fi

    if [[ -z "$VAULT_ADDR" ]]; then
        echo "ERROR: VAULT_ADDR must be set (or provide SSH_KEY for static key mode)" >&2
        exit 1
    fi

    for cmd in vault ssh-keygen; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "ERROR: $cmd not found in PATH" >&2
            exit 1
        fi
    done

    EPHEMERAL_DIR=$(mktemp -d)
    chmod 700 "$EPHEMERAL_DIR"
    SSH_KEY="${EPHEMERAL_DIR}/id_rsa"

    echo "Generating ephemeral key pair..."
    ssh-keygen -q -t rsa -N '' -f "$SSH_KEY"

    if [[ -z "${VAULT_TOKEN:-}" ]]; then
        if [[ -z "$VAULT_AUTH_GITHUB_TOKEN" ]]; then
            echo "ERROR: VAULT_AUTH_GITHUB_TOKEN required (GitHub PAT with read:org scope)" >&2
            exit 1
        fi
        echo "Authenticating to Vault via GitHub..."
        export VAULT_TOKEN
        VAULT_TOKEN=$(vault login -method=github -token-only)
    else
        echo "Using existing VAULT_TOKEN..."
    fi

    echo "Requesting signed certificate from Vault..."
    echo "  Mount: $VAULT_SSH_MOUNT, Role: $VAULT_SSH_ROLE"

    vault write -field=signed_key \
        "${VAULT_SSH_MOUNT}/sign/${VAULT_SSH_ROLE}" \
        public_key=@"${SSH_KEY}.pub" > "${SSH_KEY}-cert.pub"

    chmod 600 "${SSH_KEY}-cert.pub"

    cert_expiry=$(ssh-keygen -L -f "${SSH_KEY}-cert.pub" 2>/dev/null | grep "Valid:" | sed 's/.*to //')
    echo "  Certificate issued (expires: ${cert_expiry:-unknown})"
}

ssh_user="${SSH_USER:-$(whoami)}"

start_tunnel() {
    local bastion="$1"
    local spec="$2"

    local local_port remote_host remote_port
    IFS=':' read -r local_port remote_host remote_port <<<"$spec"

    echo "Tunnel: localhost:$local_port -> $remote_host:$remote_port (via $bastion)"

    # shellcheck disable=SC2086
    ssh -f -N -L "${local_port}:${remote_host}:${remote_port}" \
        -i "$SSH_KEY" \
        $SSH_OPTS \
        "${ssh_user}@${bastion}"

    local pid
    pid=$(pgrep -f "ssh.*-L.*${local_port}:${remote_host}:${remote_port}" | tail -1)
    tunnel_pids+=("$pid")
    echo "  Started (PID $pid)"
}

obtain_key
echo ""

TUNNEL_CONFIG="${1:-}"

if [[ -f "$TUNNEL_CONFIG" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ -z "${line// /}" ]] && continue

        read -r bastion spec <<<"$line"
        start_tunnel "$bastion" "$spec"
    done <"$TUNNEL_CONFIG"
else
    bastion="$1"
    shift
    for spec in "$@"; do
        start_tunnel "$bastion" "$spec"
    done
fi

echo ""
echo "All tunnels established. Press Ctrl+C to close."
echo "Active tunnels:"
for pid in "${tunnel_pids[@]}"; do
    ps -p "$pid" -o pid,args= 2>/dev/null | sed 's/^/  /'
done

wait
