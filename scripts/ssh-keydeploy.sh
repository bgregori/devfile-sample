#!/usr/bin/env bash
set -euo pipefail

# Deploy SSH public keys from Vault to target hosts. Keys are stored centrally
# in Vault and pushed to authorized_keys on each host.

VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR must be set}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
VAULT_KEY_PATH="${VAULT_KEY_PATH:-secret/ssh-keys}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <user> <host> [host...]

Reads SSH public keys from Vault and deploys them to authorized_keys on the
specified hosts.

Vault stores keys at: ${VAULT_KEY_PATH}/<user>
Each secret should have numbered keys (key1, key2, ...) containing public keys.

Arguments:
  user     The user whose keys to deploy (maps to Vault path)
  host     One or more target hosts

Environment:
  VAULT_ADDR       Vault server address (required)
  VAULT_KEY_PATH   Base Vault path for SSH keys (default: secret/ssh-keys)
  SSH_KEY          SSH private key for connecting to hosts (default: ~/.ssh/id_rsa)
  SSH_USER         User to SSH as on target hosts (default: same as key user)

Examples:
  $(basename "$0") admin bastion-1.example.com bastion-2.example.com
  SSH_USER=root $(basename "$0") deployer worker-{1..5}.example.com
EOF
    exit 1
}

[[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

KEY_USER="$1"
shift
HOSTS=("$@")
SSH_USER="${SSH_USER:-$KEY_USER}"

for cmd in vault ssh; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found in PATH" >&2
        exit 1
    fi
done

echo "Fetching keys for '$KEY_USER' from Vault..."

keys_json=$(vault kv get -format=json "${VAULT_KEY_PATH}/${KEY_USER}" 2>&1) || {
    echo "ERROR: Could not read keys from ${VAULT_KEY_PATH}/${KEY_USER}" >&2
    exit 1
}

keys=$(echo "$keys_json" | jq -r '.data.data // .data | to_entries[] | .value')

if [[ -z "$keys" ]]; then
    echo "ERROR: No keys found at ${VAULT_KEY_PATH}/${KEY_USER}" >&2
    exit 1
fi

key_count=$(echo "$keys" | wc -l | tr -d ' ')
echo "Found $key_count key(s)"

authorized_content=$(echo "$keys" | sort -u)

deployed=0
failed=0

for host in "${HOSTS[@]}"; do
    echo ""
    echo "--- $host ---"

    if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${SSH_USER}@${host}" true 2>/dev/null; then
        echo "  FAILED: Cannot connect to ${SSH_USER}@${host}" >&2
        failed=$((failed + 1))
        continue
    fi

    ssh -i "$SSH_KEY" "${SSH_USER}@${host}" bash <<REMOTE
set -euo pipefail
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Preserve keys not managed by this tool (lines without the vault-managed marker)
grep -v '# vault-managed' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp 2>/dev/null || true

# Append vault-managed keys
cat >> ~/.ssh/authorized_keys.tmp <<'KEYS'
$(echo "$authorized_content" | sed 's/$/ # vault-managed/')
KEYS

mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
REMOTE

    echo "  OK: $key_count key(s) deployed"
    deployed=$((deployed + 1))
done

echo ""
echo "==========================="
echo "Deployed to $deployed host(s), $failed failed"
[[ $failed -gt 0 ]] && exit 1
exit 0
