#!/usr/bin/env bash
# Fetch the k3s kubeconfig from the host and rewrite the server address.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

target="${1:-${HOME}/.kube/testsight-dedicated.yaml}"

mkdir -p "$(dirname "${target}")"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
chmod 600 "${tmp}"

host_ip="$(testsight_host_ip)"
ssh "$(testsight_ssh_user)@$(testsight_ssh_target)" 'sudo -n cat /etc/rancher/k3s/k3s.yaml' > "${tmp}"

# Rewrite the loopback server address to the host's LAN address from host_vars.
# The k3s certificate already carries it because the role passes
# --tls-san <testsight_host_ip>.
sed -i "s#https://127.0.0.1:6443#https://${host_ip}:6443#" "${tmp}"

if grep -q 'https://127.0.0.1:6443' "${tmp}"; then
  echo "error: could not rewrite the server address in the kubeconfig" >&2
  exit 1
fi

install -m 600 "${tmp}" "${target}"
echo "wrote ${target} (server: https://${host_ip}:6443)"
