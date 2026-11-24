#!/usr/bin/env bash
# Dump the host Postgres database, verify the dump, prune old backups, and run
# an optional offsite copy command. Install through the systemd timer.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  echo "error: .env is missing in $(pwd)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/testsight}"
RETENTION="${BACKUP_RETENTION_DAYS:-14}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
base="${BACKUP_DIR}/testsight-${timestamp}.dump"

trap 'rm -f "${base}.gz" "${base}.gz.sha256"' ERR
mkdir -p "$BACKUP_DIR"

echo "dumping ${POSTGRES_DB} to ${base}.gz"
docker compose -f docker-compose.yml exec -T postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner \
  | gzip -9 > "${base}.gz"

if [[ ! -s "${base}.gz" ]]; then
  echo "error: backup is empty" >&2
  rm -f "${base}.gz"
  exit 1
fi

gzip -t "${base}.gz"
sha256sum "${base}.gz" > "${base}.gz.sha256"
echo "wrote ${base}.gz"

# Retention compares the timestamp embedded in the filename, not the file's
# mtime: a dump copied in from elsewhere would otherwise be judged by its copy
# time, and touching an old backup would keep it alive.
cutoff="$(date -u -d "-${RETENTION} days" +%Y%m%dT%H%M%SZ)"
for f in "${BACKUP_DIR}"/testsight-*.dump.gz "${BACKUP_DIR}"/testsight-*.dump.gz.sha256; do
  [[ -e "${f}" ]] || continue
  stamp="$(basename "${f}" | sed -n 's/^testsight-\([0-9]\{8\}T[0-9]\{6\}Z\).*/\1/p')"
  # Unparseable names are left alone rather than deleted.
  [[ -n "${stamp}" ]] || continue
  if [[ "${stamp}" < "${cutoff}" ]]; then
    rm -f "${f}"
  fi
done

if [[ -n "${OFFSITE_COPY_CMD:-}" ]]; then
  echo "running offsite copy"
  BACKUP_FILE="${base}.gz" bash -c "$OFFSITE_COPY_CMD"
fi

echo "backup complete"
