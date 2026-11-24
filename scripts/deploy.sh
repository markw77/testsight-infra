#!/usr/bin/env bash
# Provision a fresh server end to end from its LAN address.
#
#   ./scripts/deploy.sh --ip 192.168.8.201 --cidr 192.168.8.0/24
#
# Writes the address into the gitignored host_vars file, then runs the steps
# from docs/bring-up.md in order: site.yml, kubeconfig, bootstrap, verify.
#
# The vault is required rather than created: make secrets-init is interactive and
# a CI runner cannot answer its prompts, so a missing vault stops the run with a
# pointer to the manual step.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/.." && pwd)"
# shellcheck source=../cluster-bootstrap/scripts/lib.sh
. "${repo_root}/cluster-bootstrap/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh --ip <lan-ip> [--cidr <lan-cidr>] [options]

  --ip <addr>          LAN address of the target host (required)
  --cidr <cidr>        LAN CIDR allowed through the firewall (default: /24 of --ip)
  --ssh-key <key>      public key to install; defaults to ssh_authorized_key in
                       the existing host_vars file
  --ssh-user <user>    provisioning user (default: marek, or TESTSIGHT_SSH_USER)
  --skip-site          skip ansible site.yml (host already provisioned)
  --skip-verify        skip verify.yml and the backup/restore checks
  -h, --help           this text

Environment:
  ANSIBLE_VAULT_PASSWORD_FILE   required unless the vault is unencrypted
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

ip=""
cidr=""
ssh_key=""
host_vars="${repo_root}/ansible/host_vars/testsight/vars.yml"
skip_site=0
skip_verify=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) ip="${2:-}"; shift 2 ;;
    --cidr) cidr="${2:-}"; shift 2 ;;
    --ssh-key) ssh_key="${2:-}"; shift 2 ;;
    --ssh-user) export TESTSIGHT_SSH_USER="${2:-}"; shift 2 ;;
    --skip-site) skip_site=1; shift ;;
    --skip-verify) skip_verify=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "${ip}" ]] || { usage >&2; die "--ip is required"; }
[[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "not an IPv4 address: ${ip}"
if [[ -z "${cidr}" ]]; then
  cidr="$(printf '%s' "${ip}" | awk -F. '{print $1"."$2"."$3".0/24"}')"
fi
[[ "${cidr}" =~ ^[0-9./]+$ ]] || die "not a CIDR: ${cidr}"

export TESTSIGHT_HOST_IP="${ip}"
export TESTSIGHT_HOST="${ip}"

require ansible-playbook
require awk
require ssh

vault_file="${repo_root}/ansible/group_vars/all/vault.yml"
[[ -f "${vault_file}" ]] || die "${vault_file} is missing; run 'make secrets-init' first"
: "${ANSIBLE_VAULT_PASSWORD_FILE:?set ANSIBLE_VAULT_PASSWORD_FILE (see docs/bring-up.md)}"
[[ -r "${ANSIBLE_VAULT_PASSWORD_FILE}" ]] || die "cannot read ${ANSIBLE_VAULT_PASSWORD_FILE}"

# The key that ends up in ssh_authorized_key must be one this workstation can
# present, otherwise the ssh role stops before hardening. Default to the public
# half of the key ssh would use, or keep whatever host_vars already has.
if [[ -z "${ssh_key}" && -f "${host_vars}" ]]; then
  ssh_key="$(sed -n 's/^ssh_authorized_key:[[:space:]]*//p' "${host_vars}" | head -n1 | sed 's/^"//; s/"$//')"
fi
if [[ -z "${ssh_key}" ]]; then
  for candidate in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
    if [[ -f "${candidate}" ]]; then
      ssh_key="$(<"${candidate}")"
      break
    fi
  done
fi
[[ -n "${ssh_key}" ]] || die "no SSH public key; pass --ssh-key or set ssh_authorized_key in ${host_vars}"

ssh_user="$(testsight_ssh_user)"

echo "==> checking ${ssh_user}@${ip}"
ssh -o BatchMode=yes -o ConnectTimeout=10 -o PasswordAuthentication=no \
  "${ssh_user}@${ip}" true ||
  die "key auth to ${ssh_user}@${ip} failed; see docs/bring-up.md prerequisites"
ssh -o BatchMode=yes -o ConnectTimeout=10 "${ssh_user}@${ip}" 'sudo -n true' ||
  die "passwordless sudo missing for ${ssh_user} on ${ip}"

if [[ -f "${host_vars}" ]]; then
  backup="${host_vars}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "${host_vars}" "${backup}"
  echo "==> backed up ${host_vars} to ${backup}"
fi

# Keep the non-address keys from an existing file; only the address and key are
# managed here.
postgres_db="$(sed -n 's/^postgres_db:[[:space:]]*//p' "${host_vars}" 2>/dev/null | head -n1 | sed 's/^"//; s/"$//')"
postgres_user="$(sed -n 's/^postgres_user:[[:space:]]*//p' "${host_vars}" 2>/dev/null | head -n1 | sed 's/^"//; s/"$//')"
postgres_db="${postgres_db:-testsight}"
postgres_user="${postgres_user:-testsight}"

mkdir -p "$(dirname "${host_vars}")"
umask 077
cat > "${host_vars}" <<EOF
# Written by scripts/deploy.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Gitignored.
# ansible_host is read from this file by inventory/hosts.yml; ansible_user lives
# in inventory/hosts.yml.

testsight_host_ip: ${ip}
testsight_lan_cidr: ${cidr}

postgres_db: ${postgres_db}
postgres_user: ${postgres_user}

# Workstation public key installed by the ssh role. It must be a key that can log
# in to ${ssh_user}@${ip}, because the role stops if key auth breaks.
ssh_authorized_key: "${ssh_key}"
EOF
echo "==> wrote ${host_vars}"

cd "${repo_root}/ansible"

if [[ "${skip_site}" -eq 0 ]]; then
  echo "==> site.yml --syntax-check"
  ansible-playbook playbooks/site.yml --syntax-check
  echo "==> site.yml"
  ansible-playbook playbooks/site.yml
  echo "==> site.yml (idempotence check, expect changed=0)"
  ansible-playbook playbooks/site.yml
fi

echo "==> kubeconfig"
bash "${repo_root}/cluster-bootstrap/scripts/fetch-kubeconfig.sh" \
  "${HOME}/.kube/testsight-dedicated.yaml"
export KUBECONFIG="${HOME}/.kube/testsight-dedicated.yaml"

echo "==> bootstrap"
"${repo_root}/cluster-bootstrap/scripts/bootstrap.sh"

if [[ "${skip_verify}" -eq 0 ]]; then
  echo "==> verify.yml"
  ansible-playbook playbooks/verify.yml
  cd "${repo_root}"
  echo "==> backup-now"
  bash "${repo_root}/cluster-bootstrap/scripts/backup-now.sh"
  echo "==> restore-test"
  bash "${repo_root}/cluster-bootstrap/scripts/restore-test.sh"
fi

echo
echo "done: https://${ip}:8080 (Argo CD), admin password in the vault"
