# Argo CD

Argo CD and Sealed Secrets are installed out of band; Argo CD cannot bootstrap
itself. Argo CD is ClusterIP-only and reached with
`kubectl port-forward`; the host has no public IP and no inbound ports.

## Install and bootstrap

`cluster-bootstrap/scripts/bootstrap.sh` is the single entry point. It runs, in
order:

1. preflight `kubectl`, `helm`, `kubeseal`, `KUBECONFIG`, cluster access;
2. `install-argocd.sh` — Helm into `argocd`, `server.service.type=ClusterIP`,
   pinned chart version, wait for rollout;
3. `install-sealed-secrets.sh` — `kubectl apply` of the pinned upstream
   `controller.yaml` release manifest into `kube-system`, wait for rollout;
4. create namespaces `argocd`, `testsight-system`, `testsight-runners`;
5. `seal-secrets.sh` — seal and apply the repository Secret, app Secret, and
   GHCR pull Secrets;
6. apply `argocd/project.yaml`;
7. apply `argocd/root-app.yaml`;
8. wait for the root Application to reach `Synced`, then warn if it is not
   `Healthy`, and print the tunnel log and port-forward commands. The wait is
   fatal: a root app that never syncs stops the script instead of printing
   access hints for a cluster that is not bootstrapped.

Every version is pinned in `cluster-bootstrap/versions.env`.

## Access

The UI is served on the LAN at `https://<host-ip>:8080` through k3s ServiceLB.
TLS terminates inside `argocd-server`, so the scheme is `https` and the
certificate is self-signed — expect a browser warning.

Access is restricted the same way as every other published port: `ufw` allows
`8080` from `testsight_lan_cidr` only, and `DOCKER-USER` mirrors that rule. The
service deliberately exposes **one** port, because klipper can bind each service
port once; a second entry becomes a node port whose number no firewall rule
knows about. Change `argocd_ui_port` in `ansible/group_vars/all/vars.yml` and the
Argo chart values together if you need a different port.

Log in as `admin` with `vault_argocd_admin_password` from the vault. It is not
the `argocd-initial-admin-secret` value: `install-argocd.sh` passes a bcrypt hash
of the vault password as `configs.secret.argocdServerAdminPassword`, so the
initial secret never applies and can be deleted.

```bash
# admin password, for reference
ANSIBLE_VAULT_PASSWORD_FILE=~/.config/testsight/vault-pass \
  ansible-vault view ansible/group_vars/all/vault.yml | grep argocd_admin
```

`kubectl -n argocd port-forward svc/argocd-server 8080:443` still works as a
fallback from the workstation, and is the only route when you are off the LAN.

## Ownership

- **AppProject `testsight`**: sources only
  `https://github.com/markw77/testsight.git`;
  destinations `testsight-system`, `testsight-runners`, `argocd`; cluster
  resource whitelist `Namespace` only.
- **Root Application `testsight-root`**: app-of-apps over
  `https://github.com/markw77/testsight.git` path `deploy/argocd/apps`, revision
  `main`, into `argocd` with `CreateNamespace=false`.
- **App Application** (in the app repo `deploy/argocd/apps/testsight.yaml`):
  the Helm chart with `values-hosted.yaml` + `values-images.yaml`.

Until the app repo contains at least one Application in `deploy/argocd/apps`,
the root app reports `Synced` with no children. That is the expected state
right after a first bootstrap, not a failure.

The `argocd-repo-testsight` Secret registers the SSH URL
(`git@github.com:markw77/testsight.git`), while the AppProject and root app use
HTTPS. Argo treats those as different repositories, so the deploy key is not
used by them; it matters only if the app repo is made private, in which case
both URLs must be switched to the SSH form first.

Argo polls Git; there is no webhook. Digest promotion by the app repo's
`deploy.yml` therefore rolls the control plane within one poll interval.

## Sync and rollback

- `argocd app sync testsight-root`, then `argocd app get testsight -o wide`
  once the child Application exists.
- Rollback is a Git revert in `testsight`; Argo syncs the previous revision.

## What Argo does not own

- Host Postgres, pgAdmin, and the backup systemd units (see `host-postgres.md`)
- The Sealed Secrets controller and its key
- The Cloudflare quick tunnel URL (ephemeral, printed in pod logs)
- Runner Jobs and per-run Secrets (created and deleted by the control plane)
