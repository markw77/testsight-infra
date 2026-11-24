#!/usr/bin/env bash
# Restore the newest host backup into a scratch database, count rows, and drop
# the scratch database. Proves the dump is restorable without touching the live
# database.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

target="$(testsight_ssh_user)@$(testsight_ssh_target)"
host_script="/tmp/testsight-restore-test.$$.sh"
backup_dir="/var/backups/testsight"
scratch="testsight_restore"

body="$(mktemp)"
trap 'rm -f "${body}"' EXIT

# The body is shipped as a file rather than piped into `ssh bash -s`, because
# `docker compose exec -T` reads the script's stdin: with a heredoc the first
# exec swallows the remaining commands and the session exits 0 having done
# nothing. Copying the file sidesteps that entirely.
cat > "${body}" <<'EOF'
set -euo pipefail
backup_dir="$1"
scratch="$2"
cd /opt/testsight/deploy/host-postgres
latest="$(ls -1t "${backup_dir}"/testsight-*.dump.gz | head -n1)"
echo "restoring ${latest}"
docker compose exec -T postgres dropdb -U testsight --if-exists "${scratch}"
# Clean up even when an assertion below fails, so a failure does not leave the
# scratch database behind.
trap 'docker compose exec -T postgres dropdb -U testsight --if-exists "${scratch}" >/dev/null 2>&1 || true' EXIT
docker compose exec -T postgres createdb -U testsight -T template0 "${scratch}"
gunzip -c "${latest}" | docker compose exec -T postgres pg_restore -U testsight -d "${scratch}" --no-owner

# The restore is proven by the fact that pg_restore succeeded. A pre-migration
# cluster legitimately has an empty schema, so only assert on tenants when the
# dump actually contains tables.
tables="$(docker compose exec -T postgres psql -U testsight -d "${scratch}" -tAc \
  "select count(*) from information_schema.tables where table_schema = 'public'")"
tables="${tables//[[:space:]]/}"
if [[ "${tables}" -eq 0 ]]; then
  echo "restore test passed; dump has no tables yet (pre-migration cluster)"
else
  docker compose exec -T postgres psql -U testsight -d "${scratch}" -c 'select count(*) from tenants;'
  echo "restore test passed; ${tables} tables restored, scratch database dropped"
fi
EOF

scp -q "${body}" "${target}:${host_script}"
ssh "${target}" "bash ${host_script} ${backup_dir} ${scratch}; rc=\$?; rm -f ${host_script}; exit \$rc"
