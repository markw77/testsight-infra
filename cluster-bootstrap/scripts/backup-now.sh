#!/usr/bin/env bash
# Run one backup on the host from the workstation. The backup script itself is
# installed by the backup role and reads its own .env; this only wraps the SSH
# hop so the host address comes from ansible/host_vars/testsight/vars.yml.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

host_dir="/opt/testsight/deploy/host-postgres"

ssh "$(testsight_ssh_user)@$(testsight_ssh_target)" \
  "cd ${host_dir} && ./backup.sh"
