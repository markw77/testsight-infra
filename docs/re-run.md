# Re-run and upgrades

Everything is idempotent. Re-running `playbooks/site.yml` must report
`changed=0`. Re-running `scripts/bootstrap.sh` must leave Argo and the app
Applications Synced/Healthy.

## Routine re-run

```bash
cd ansible
ansible-playbook playbooks/site.yml --check --diff
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/verify.yml
```

## Version updates

All versions are pinned in `cluster-bootstrap/versions.env`. Update a pin, then:

| Component | Action |
|---|---|
| k3s | change `K3S_VERSION`, re-run `site.yml` (k3s role), drain first if workloads exist |
| Argo CD | change `ARGOCD_CHART_VERSION`, run `scripts/install-argocd.sh` |
| Sealed Secrets | change `SEALED_SECRETS_VERSION` **and** `KUBESEAL_VERSION` (they must match), run `scripts/install-sealed-secrets.sh`, then re-check that sealed manifests still decrypt. The install is `kubectl apply` of the upstream release manifest, so there is no `helm uninstall` rollback; controller keys persist across upgrades but **not** across cluster rebuilds |
| Postgres / pgAdmin image | change the role template pin, take a backup, re-run the role |

Review app chart and infra pins together; drift between them is a known risk.

## Secret rotation

See `secrets.md`. In short: `ansible-vault edit`, `make seal`, apply, restart
the consumer, verify.

## Digest rollouts

The app repo's `deploy.yml` commits new digests into
`deploy/helm/testsight/values-images.yaml`. Argo polls `main` and rolls the
control plane. Runner Jobs pick up the new digest on their next run.

## Backup and restore rehearsal

Monthly:

```bash
make backup-now
make restore-test
```

`restore-test` restores the newest dump into a scratch Postgres container,
counts rows, and drops the scratch database.

## Server-to-server migration

1. `make backup-now`; copy the newest `*.dump.gz` and `.sha256` off-host.
2. Provision the new host per `bring-up.md` (bare Ubuntu, Ansible).
3. Restore the dump into the new host's Postgres:

   ```bash
   gunzip -c testsight-YYYY.dump.gz \
     | docker compose exec -T postgres pg_restore -U testsight -d testsight --no-owner
   ```

4. Update `ansible/host_vars/testsight/vars.yml` with the new IP; re-run
   `site.yml`.
5. Re-point `~/testsight-infra` at the new host, `make kubeconfig`.
6. `make bootstrap` on the new cluster. Because the cluster is new, the
   Sealed Secrets key is new, so the sealed files must be regenerated; they are
   gitignored, and `bootstrap` runs `make seal` for you.
7. Verify the migrated data with `/v1/usage` and the app smoke checks; then
   retire the old host.

## Argo CD sync and rollback

```bash
argocd app sync testsight-root
argocd app get testsight -o wide
```

App rollback is a Git revert in `testsight`; Argo syncs the previous revision.
