# Disaster recovery

Two scenarios: a cluster rebuild where the host survives (data recoverable from
the host backup), and a host loss where the only recovery source is an off-host
copy of a backup. There is no recovery for data that was never backed up.

## Rollback reality

- **Before a wipe**, the live host is the only rollback. Once wiped, it is not a
  rollback.
- **After a wipe**, rebuild forward from Ansible and the app repo.
- **App rollback** is a Git revert in `testsight`; Argo syncs the previous
  revision.
- **Database rollback** only exists through a backup dump. The initial clean
  rebuild intentionally discarded the old empty cluster and took no dump.

## Scenario A — cluster rebuild, host intact

The database lives in a host Docker volume and survives a k3s wipe.

1. Confirm a recent backup exists: `make backup-now`, then check
   `/var/backups/testsight` and its `.sha256`.
2. Remove the cluster:

   ```bash
   sudo /usr/local/bin/k3s-uninstall.sh
   sudo rm -rf /etc/rancher /var/lib/rancher
   ```

   Do **not** remove `/opt/testsight` or the Docker volumes.
3. Re-run `ansible-playbook playbooks/site.yml` (installs k3s again).
4. `make kubeconfig`, then `make seal` — the new cluster has a new Sealed
   Secrets key, so every sealed manifest must be regenerated (the files are
   gitignored; nothing is committed).
5. `make bootstrap`.
6. Verify: `/readyz`, `/v1/usage`, tunnel, smoke checks from `bring-up.md`.
7. Confirm runner Jobs and per-run Secrets are reaped after a run.

## Scenario B — host lost

1. Provision replacement hardware with minimal Ubuntu 26.04.
2. Restore the newest off-host backup (see `re-run.md`,
   "Server-to-server migration").
3. Re-run `site.yml`, `make kubeconfig`, `make seal`, `make bootstrap`.
4. Verify against `bring-up.md`.

Without an off-host copy, Scenario B loses all data. This is why the runbook
requires a manual off-host copy before any rebuild and after major changes.

## Data-loss rebuild (initial clean rebuild)

The initial rebuild was deliberate:

1. Wipe the server (Phase 0): `k3s-uninstall.sh`, remove `/opt/testsight`,
   `/var/backups/testsight`, `/etc/rancher`, `/var/lib/rancher`, `~/testsight`.
2. Reinstall or reuse minimal Ubuntu 26.04 with the `marek` user, SSH key, and
   sudo.
3. `ansible-playbook playbooks/site.yml` (check, apply, second idempotence run).
4. Verify host posture (`verify.yml`).
5. `make bootstrap`. The migration hook creates `0001_initial` on the empty
   database; the control plane creates the bootstrap tenant.
6. Verify `/readyz`, tunnel, smoke checks, and that only the bootstrap tenant
   and smoke-test rows exist.
7. Take the first backup and test-restore it (`make backup-now`,
   `make restore-test`).
8. Re-provision tenant API keys with `testsight-admin` and update clients.

## Re-sealing after any rebuild

A new cluster means a new Sealed Secrets controller key. `make seal` regenerates
and applies every sealed manifest; the files are gitignored, so nothing is
committed. Old sealed files cannot be decrypted by the new controller. Back up
the controller key out of band so a future rebuild can reuse existing sealed
files when the key is preserved.

## Verification after recovery

- Node Ready; Traefik absent.
- Argo CD and Sealed Secrets ready; both Applications Synced/Healthy.
- Migration hook completed; `/readyz` database and migration head pass.
- Private images pull in both namespaces.
- Tunnel serves health, readiness, auth, and `/v1/usage`.
- Run lifecycle (sync, async, stored test, cancel) and Job/Secret cleanup pass.
- NetworkPolicy blocks metadata and private ranges.
