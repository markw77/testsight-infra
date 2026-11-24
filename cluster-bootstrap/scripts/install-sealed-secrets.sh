#!/usr/bin/env bash
# Install the Sealed Secrets controller into kube-system from the pinned
# upstream release manifest.
#
# This used to be a Helm chart, but the project moved from bitnami-labs to
# bitnami and the old chart repository (bitnami-labs.github.io/sealed-secrets)
# is gone. Upstream now publishes controller.yaml per release, which pins the
# controller image the same way a chart pin did.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
. "${here}/../versions.env"

: "${KUBECONFIG:?set KUBECONFIG}"
: "${SEALED_SECRETS_VERSION:?SEALED_SECRETS_VERSION is not set in versions.env}"

manifest="https://github.com/bitnami/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"

# Applying the CRD before the Deployment avoids a first-run race where the
# controller starts before its CRD is established.
kubectl apply -f "${manifest}"

kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=300s

if ! kubeseal --version >/dev/null 2>&1; then
  echo "warning: kubeseal not found; install ${KUBESEAL_VERSION} and add it to PATH" >&2
else
  installed_kubeseal="$(kubeseal --version 2>/dev/null | awk '{print $NF}')"
  if [[ "v${installed_kubeseal#v}" != "${KUBESEAL_VERSION}" ]]; then
    echo "warning: kubeseal ${installed_kubeseal} does not match pinned controller ${SEALED_SECRETS_VERSION}" >&2
  fi
fi

echo "Sealed Secrets ${SEALED_SECRETS_VERSION} installed"
