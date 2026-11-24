# Host Postgres and pgAdmin

This stack is **not** managed by Argo CD or the Helm chart. It runs on the
dedicated host with host Docker so a Kubernetes wipe does not delete the
database. The `postgres` and `backup` Ansible roles own it.

- Postgres: `postgres:16-alpine`, published on `<host-ip>:5432`, named volume
  `testsight-host_testsight-postgres-data`.
- pgAdmin: `dpage/pgadmin4:8.14`, published on `<host-ip>:5050`, LAN-only.
- Both are LAN-only; the host has no public IP and no inbound forwarding.

## What Ansible renders

`roles/postgres` writes into `/opt/testsight/deploy/host-postgres`:

| File | Source | Mode |
|---|---|---|
| `docker-compose.yml` | `roles/postgres/templates/docker-compose.yml` | 0644 |
| `pg_hba.conf` | `roles/postgres/templates/pg_hba.conf` | 0644 |
| `pgadmin-servers.json` | `roles/postgres/files/pgadmin-servers.json` | 0644 |
| `.env` | `roles/postgres/templates/.env.example` (vault values) | 0600 |

The `.env` file is rendered from Ansible Vault. It is never committed. The
password is URL-encoded by Ansible when it renders `DATABASE_URL`, so the same
value in the sealed cluster Secret stays valid.

## Authentication

`PGPASSWORD` is set inside the postgres container so `docker compose exec`
client tools authenticate over the local socket; network connections still use
`scram-sha-256` from `pg_hba.conf`.

`pg_hba.conf` allows only:

- local Unix sockets and loopback,
- k3s pod traffic from the pod CIDR,
- traffic SNATed to the node address,
- the dedicated pgAdmin Docker network.

Everything else, including LAN clients that reach the published 5432 port, is
rejected. Administer the database with:

```bash
cd /opt/testsight/deploy/host-postgres
docker compose exec postgres psql -U testsight -d testsight
```

or pgAdmin at `http://<host-ip>:5050` using the credentials from `.env`.
The pre-provisioned pgAdmin server entry connects to host `postgres:5432`.

Do not publish 5432 on `0.0.0.0`. If you temporarily need `psql` from another
machine, use an SSH tunnel:

```bash
ssh -L 5432:127.0.0.1:5432 marek@<host-ip>
# in another terminal
psql 'postgresql://testsight:...@127.0.0.1:5432/testsight'
```

Docker publishes ports with its own NAT rules, which bypass UFW, so the
`firewall` role installs `DOCKER-USER` rules that drop connections to 5432 and
5050 unless they come from the pod CIDR, the pgAdmin network, or the host
itself. `pg_hba.conf` remains the primary control: it rejects every source it
does not list.

kube-router's policy chain (`KUBE-ROUTER-FORWARD`) is ordered before
`DOCKER-USER` and also drops *new* flows to pod addresses, so a blocked LAN
client is usually stopped there first. That is incidental. Established flows
short-circuit through `KUBE-FORWARD` and skip kube-router entirely, which is the
case `DOCKER-USER` exists to cover — so treat the rules as required, not
redundant, and do not remove them because their counters look idle.

## Backups

`roles/backup` installs:

- `/usr/local/bin/testsight-backup.sh` (from `roles/backup/files/backup.sh`),
- `testsight-backup.service` and `testsight-backup.timer` (daily 02:30 UTC),
- `/var/backups/testsight` owned `marek:marek` mode `0750`.

`backup.sh`:

- runs `pg_dump --format=custom --no-owner` through `docker compose exec -T`,
- gzips the dump and verifies it with `gzip -t`,
- writes a SHA-256 checksum,
- deletes backups older than `BACKUP_RETENTION_DAYS` (default 14),
- runs `OFFSITE_COPY_CMD` when set. No offsite copy is configured.

`make backup-now` runs one backup from the workstation.

Test a restore regularly on a scratch database (`make restore-test`):

```bash
gunzip -c /var/backups/testsight/testsight-YYYY...dump.gz \
  | docker compose exec -T postgres createdb -U testsight -T template0 testsight_restore
gunzip -c /var/backups/testsight/testsight-YYYY...dump.gz \
  | docker compose exec -T postgres pg_restore -U testsight -d testsight_restore --no-owner
docker compose exec postgres psql -U testsight -d testsight_restore -c 'select count(*) from runs;'
docker compose exec postgres dropdb -U testsight testsight_restore
```

To restore the live database, stop the control plane first (disable Argo
auto-sync or scale it to zero), restore into the existing `testsight` database,
then let the control plane read the Alembic head again.

## Upgrades

Postgres runs the pinned `postgres:16-alpine` image. Take a fresh backup and
read the release notes before changing the major version; the data directory is
major-version specific.
