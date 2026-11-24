#!/usr/bin/env bash
# Bootstrap Alerts: install Argo CD and Sealed Secrets, create namespaces, seal
# and apply the cluster Secrets, then apply the AppProject and root Application.
# Argo CD owns only app resources afterwards.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"
# shellcheck source=../versions.env
. "${here}/../versions.env"

# Single source of truth: testsight_host_ip from host_vars, no hostname -I.
host_ip="$(testsight_host_ip)"
export TESTSIGHT_HOST_IP="${host_ip}"

# Ansible is required by seal-secrets.sh, not here; see that script.
require kubectl
require helm
require kubeseal
: "${KUBECONFIG:?set KUBECONFIG}"

kubectl version --request-timeout=10s >/dev/null
kubectl get nodes >/dev/null

"${here}/install-argocd.sh"
"${here}/install-sealed-secrets.sh"

for ns in argocd testsight-system testsight-runners; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

"${here}/seal-secrets.sh"

kubectl apply -f "${here}/../argocd/project.yaml"
kubectl apply -f "${here}/../argocd/root-app.yaml"

# Fail loudly. A cluster whose root Application never syncs is not bootstrapped,
# and printing the access hints below would suggest otherwise. An empty app repo
# is the usual cause, so the conditions carry the reason.
echo "waiting for the root Application"
if ! kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/testsight-root --timeout=300s; then
  echo "error: testsight-root did not reach Synced" >&2
  kubectl -n argocd get applications || true
  kubectl -n argocd get application testsight-root \
    -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' >&2 || true
  exit 1
fi

kubectl -n argocd get applications
if ! kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  application/testsight-root --timeout=120s; then
  echo "warning: testsight-root is Synced but not Healthy; see 'kubectl -n argocd get application testsight-root -o yaml'" >&2
fi

echo "tunnel logs:  kubectl -n testsight-system logs deploy/testsight-cloudflared -f | grep trycloudflare"
echo "argo access:  kubectl -n argocd port-forward svc/argocd-server 8080:443"
