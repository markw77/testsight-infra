#!/usr/bin/env bash
# Render secrets from Ansible Vault, seal them with kubeseal, apply them to the
# cluster, and delete the plaintext. Safe to re-run; regenerate after any
# cluster rebuild because the Sealed Secrets key changes.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"
out_dir="${here}/../secrets"
vault_pass="${ANSIBLE_VAULT_PASSWORD_FILE:-${HOME}/.config/testsight/vault-pass}"
vault_file="${repo_root}/ansible/group_vars/all/vault.yml"

: "${KUBECONFIG:?set KUBECONFIG}"
export ANSIBLE_VAULT_PASSWORD_FILE="${vault_pass}"

# Ansible is used only here, so it is required here rather than in bootstrap.sh.
require ansible
require kubeseal
require kubectl
require jq

tmp="$(mktemp -d)"
chmod 700 "${tmp}"
trap 'rm -rf "${tmp}"' EXIT

# Reads a vault value into a shell variable. Uses ansible-vault view to decrypt
# the file directly (avoids ansible debug's $REDACTED$ redaction of values whose
# names match sensitive patterns like *token*).
read_vault() {
  local key="$1" value
  value="$(ansible-vault view "${vault_file}" --vault-password-file="${vault_pass}" 2>/dev/null |
    sed -n "s/^${key}: //p" |
    sed 's/^"//; s/"$//')"
  if [[ -z "${value}" ]]; then
    echo "error: could not read ${key} from ${vault_file}" >&2
    return 1
  fi
  printf '%s\n' "${value}"
}

postgres_password="$(read_vault vault_postgres_password)"
bootstrap_key="$(read_vault vault_bootstrap_api_key)"
ghcr_user="$(read_vault vault_ghcr_username)"
ghcr_token="$(read_vault vault_ghcr_token)"
repo_key="$(read_vault vault_argocd_repo_ssh_key)"
cloudflare_tunnel_token="$(read_vault vault_cloudflare_tunnel_token)"

host_ip="$(testsight_host_ip)"
# Same source as the compose stack and pg_hba.conf: host_vars. Reading the
# environment here used to allow a silent mismatch with the rendered .env.
db_name="$(testsight_host_var postgres_db)"
db_user="$(testsight_host_var postgres_user)"

urlencoded_password="$(
  ansible localhost -c local -m ansible.builtin.debug \
    -a "msg={{ '${postgres_password}' | urlencode | to_json }}" 2>/dev/null |
    sed -n 's/.*"msg": "\(.*\)"/\1/p' |
    # The value is a JSON string; unescape it with jq, as read_vault does.
    sed 's/^/"/; s/$/"/' | jq -r .
)"

cat > "${tmp}/repository.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-repo-testsight
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: git@github.com:markw77/testsight.git
  sshPrivateKey: |
$(printf '%s\n' "${repo_key}" | sed 's/^/    /')
EOF

cat > "${tmp}/hosted.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: testsight-hosted-secrets
  namespace: testsight-system
type: Opaque
stringData:
  DATABASE_URL: postgresql+asyncpg://${db_user}:${urlencoded_password}@${host_ip}:5432/${db_name}
  BOOTSTRAP_API_KEY: ${bootstrap_key}
EOF

# Built with jq so a token containing quotes or backslashes cannot produce an
# invalid dockerconfigjson that only fails later, at image pull time.
auth="$(printf '%s:%s' "${ghcr_user}" "${ghcr_token}" | base64 -w0)"
dockerconfig="$(jq -cn \
  --arg user "${ghcr_user}" \
  --arg pass "${ghcr_token}" \
  --arg auth "${auth}" \
  '{auths: {"ghcr.io": {username: $user, password: $pass, auth: $auth}}}' |
  base64 -w0)"

for ns in testsight-system testsight-runners; do
  cat > "${tmp}/ghcr-${ns}.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-pull
  namespace: ${ns}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${dockerconfig}
EOF
done

cat > "${tmp}/cloudflare-tunnel-token.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-tunnel-token
  namespace: testsight-system
type: Opaque
stringData:
  token: ${cloudflare_tunnel_token}
EOF

for f in "${tmp}"/*.yaml; do
  base="$(basename "${f}" .yaml)"
  kubeseal --controller-namespace kube-system \
    --controller-name sealed-secrets-controller \
    --format yaml < "${f}" > "${out_dir}/${base}.sealed.yaml"
  kubectl apply -f "${out_dir}/${base}.sealed.yaml"
done

echo "sealed and applied: $(cd "${out_dir}" && find . -maxdepth 1 -name '*.sealed.yaml' -printf '%f ')"
echo "sealed files are gitignored; they are regenerated per cluster from the vault"
