#!/usr/bin/env bash
# Install Argo CD with a pinned chart version. The UI is served by k3s
# ServiceLB on the host's LAN address, restricted by ufw and DOCKER-USER.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"
# shellcheck source=../versions.env
. "${here}/../versions.env"

: "${KUBECONFIG:?set KUBECONFIG}"
require helm
require kubectl
require ansible
require ansible-playbook

# The admin password is read from the vault, never from a file, and passed as a
# chart value because the chart owns argocd-secret.
#
# The chart stores the value verbatim in admin.password, so it must arrive
# already hashed: plaintext there is never accepted by the server, and a hash
# produced elsewhere survives re-runs unchanged, whereas regenerating one for
# every install would invalidate sessions on each run.
: "${ANSIBLE_VAULT_PASSWORD_FILE:?set ANSIBLE_VAULT_PASSWORD_FILE to read the Argo CD admin password}"
vault_file="${repo_root}/ansible/group_vars/all/vault.yml"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cat > "${tmp_dir}/hash-admin.yml" <<'PLAY'
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.debug:
        msg: "B64={{ (vault_argocd_admin_password | password_hash('bcrypt')) | b64encode }}"
PLAY

admin_hash="$(
  ansible-playbook "${tmp_dir}/hash-admin.yml" \
    --extra-vars "@${vault_file}" 2>/dev/null |
    grep -o 'B64=[A-Za-z0-9+/=]*' | cut -d= -f2- | base64 -d
)"
if [[ -z "${admin_hash}" || "${admin_hash}" != \$2* ]]; then
  echo "error: could not hash vault_argocd_admin_password from ${vault_file}" >&2
  exit 1
fi

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "${ARGOCD_CHART_VERSION}" \
  -f "${here}/../values/argocd-values.yaml" \
  --set-string "configs.secret.argocdServerAdminPassword=${admin_hash}" \
  --wait --timeout 10m

kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# Patch the Service to single port 8080 (klipper LoadBalancer).
# The chart defaults to ports 80/443; extra ports become NodePorts that bypass ufw.
# Apply after rollout so helm doesn't try to merge during upgrade.
kubectl -n argocd patch svc argocd-server --type='json' \
  -p='[{"op": "replace", "path": "/spec/ports", "value": [{"name": "https", "port": 8080, "protocol": "TCP", "targetPort": 8080}]}]' 2>/dev/null || true

# Report what is actually running rather than a constant from versions.env: the
# chart tags the image independently of the chart version.
running="$(kubectl -n argocd get deploy argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's#.*:##')"
echo "Argo CD chart ${ARGOCD_CHART_VERSION} installed (image tag ${running})"
