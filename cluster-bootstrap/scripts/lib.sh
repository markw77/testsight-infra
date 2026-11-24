#!/usr/bin/env bash
# Shared helpers for the cluster-bootstrap scripts. Source it without setting
# repo_root first: the default below resolves it from this file's own location,
# which works both from a script and when sourced standalone for testing:
#   # shellcheck source=lib.sh
#   . "${here}/lib.sh"
#
# repo_root is exported so shellcheck sees the assignment across the sourced
# file boundary.
#
# The host address has a single source of truth: testsight_host_ip in the
# gitignored ansible/host_vars/testsight/vars.yml. These helpers only read it;
# TESTSIGHT_HOST_IP and TESTSIGHT_HOST remain available as explicit overrides.

# Plain assignment at top level so `shellcheck -x` sees it when following the
# `source=lib.sh` directives. An earlier repo_root from the caller is kept.
: "${repo_root:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export repo_root

testsight_host_vars_file() {
  printf '%s\n' "${repo_root}/ansible/host_vars/testsight/vars.yml"
}

# Prints testsight_host_ip, or fails with an actionable message. Never falls back
# to hostname -I: on a workstation that would silently yield the workstation's
# own address and bake it into the kubeconfig and DATABASE_URL.
testsight_host_ip() {
  if [[ -n "${TESTSIGHT_HOST_IP:-}" ]]; then
    printf '%s\n' "${TESTSIGHT_HOST_IP}"
    return 0
  fi

  local file ip
  file="$(testsight_host_vars_file)"
  if [[ ! -f "${file}" ]]; then
    echo "error: ${file} is missing; copy ansible/host_vars/testsight/vars.yml.example" >&2
    return 1
  fi

  ip="$(sed -n 's/^testsight_host_ip:[[:space:]]*//p' "${file}" | head -n1 | sed 's/[[:space:]]*$//')"
  ip="${ip%\"}"
  ip="${ip#\"}"
  ip="${ip%\'}"
  ip="${ip#\'}"

  if [[ -z "${ip}" ]]; then
    echo "error: testsight_host_ip is not set in ${file}" >&2
    return 1
  fi
  if [[ ! "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "error: testsight_host_ip '${ip}' in ${file} is not an IPv4 address" >&2
    return 1
  fi

  printf '%s\n' "${ip}"
}

# Prints the SSH target: TESTSIGHT_HOST when set, otherwise the host IP.
testsight_ssh_target() {
  if [[ -n "${TESTSIGHT_HOST:-}" ]]; then
    printf '%s\n' "${TESTSIGHT_HOST}"
    return 0
  fi
  testsight_host_ip
}

# Prints the SSH user, matching ansible_user in ansible/inventory/hosts.yml.
testsight_ssh_user() {
  printf '%s\n' "${TESTSIGHT_SSH_USER:-marek}"
}

# Fails with a clear message when a required command is missing. Kept in one
# place so callers do not each reinvent it.
require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: $1 is required" >&2; exit 1; }
}

# Prints a scalar value from the gitignored host_vars file. Fails when the key
# is absent so a rename cannot silently fall back to a default.
testsight_host_var() {
  local key="$1" value file
  file="$(testsight_host_vars_file)"
  if [[ ! -f "${file}" ]]; then
    echo "error: ${file} is missing; copy ansible/host_vars/testsight/vars.yml.example" >&2
    return 1
  fi
  value="$(sed -n "s/^${key}:[[:space:]]*//p" "${file}" | head -n1 | sed 's/[[:space:]]*$//')"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  if [[ -z "${value}" ]]; then
    echo "error: ${key} is not set in ${file}" >&2
    return 1
  fi
  printf '%s\n' "${value}"
}
