#!/usr/bin/env bash
# Generate fresh secret material for Ansible Vault and the Argo deploy key.
# Idempotent: refuses to overwrite an existing vault.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"
config_dir="${HOME}/.config/testsight"
vault_pass="${VAULT_PASS:-${config_dir}/vault-pass}"
# shellcheck disable=SC2154  # repo_root is assigned by lib.sh above
vault_file="${repo_root}/ansible/group_vars/all/vault.yml"
deploy_key="${config_dir}/testsight-infra-deploy-key"

# Check the tools before prompting: this script reads interactive input, and
# failing after the prompts would waste the values the user just typed.
require openssl
require ssh-keygen
require ansible-vault

if [[ -e "${vault_file}" ]]; then
  echo "error: ${vault_file} already exists; use 'ansible-vault edit' to change values" >&2
  exit 1
fi

mkdir -p "${config_dir}"
chmod 700 "${config_dir}"

if [[ ! -f "${vault_pass}" ]]; then
  umask 077
  openssl rand -base64 48 > "${vault_pass}"
  chmod 600 "${vault_pass}"
  echo "wrote vault password to ${vault_pass}"
fi

if [[ ! -f "${deploy_key}" ]]; then
  umask 077
  ssh-keygen -q -t ed25519 -N '' -C "testsight-infra@$(hostname)" -f "${deploy_key}"
  echo "wrote deploy key to ${deploy_key}"
  echo "add ${deploy_key}.pub to github.com/markw77/testsight as a read-only deploy key"
fi

postgres_password="$(openssl rand -base64 32 | tr -d '\n/+=@:')"
bootstrap_key="ts_$(openssl rand -hex 32)"

read -r -p "pgAdmin email: " pgadmin_email
read -r -s -p "pgAdmin password: " pgadmin_password
echo
read -r -p "GHCR username: " ghcr_username
read -r -s -p "GHCR token (read:packages): " ghcr_token
echo

umask 077
plain="$(mktemp)"
trap 'rm -f "${plain}"' EXIT
cat > "${plain}" <<EOF
---
vault_postgres_password: "${postgres_password}"
vault_pgadmin_email: "${pgadmin_email}"
vault_pgadmin_password: "${pgadmin_password}"
vault_bootstrap_api_key: "${bootstrap_key}"
vault_ghcr_username: "${ghcr_username}"
vault_ghcr_token: "${ghcr_token}"
vault_argocd_repo_ssh_key: |
$(sed 's/^/  /' "${deploy_key}")
EOF

ANSIBLE_VAULT_PASSWORD_FILE="${vault_pass}" \
  ansible-vault encrypt --output "${vault_file}" "${plain}"

echo "wrote encrypted ${vault_file}"
echo "export ANSIBLE_VAULT_PASSWORD_FILE=${vault_pass}"
