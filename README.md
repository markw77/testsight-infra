# testsight-infra

Host provisioning and cluster bootstrap for the testsight hosted deployment.
The application lives in [testsight](https://github.com/markw77/testsight); this
repository owns everything around it.

| Area | Owned here | Not here |
|---|---|---|
| Host OS | base, ssh, firewall, docker, k3s | app code, chart |
| Database | host Postgres, pgAdmin, backup timer | schema (the chart's migration hook) |
| Cluster | Argo CD, Sealed Secrets, AppProject, root Application | app Application, chart values |
| Secrets | vault, per-cluster sealed manifests | plaintext secrets |
| Runbooks | bring-up, re-run, DR, host Postgres, secrets, Argo | app operations |

The app repo deploys itself through Argo CD once this repository has applied the
root Application.

## Layout

```text
ansible/           host provisioning (roles, inventory, vault)
cluster-bootstrap/ Argo CD + Sealed Secrets install, sealing, bootstrap
docs/              bring-up, re-run, disaster recovery, and references
```

## Quick start

```bash
make install-tools
cp ansible/host_vars/testsight/vars.yml.example ansible/host_vars/testsight/vars.yml  # then edit
make secrets-init
make site
make kubeconfig
make bootstrap
make verify
```

Read `docs/bring-up.md` first. It covers the host prerequisites that this
quick start omits: an authorised workstation SSH key, passwordless sudo for the
provisioning user, and the GitHub deploy key registration.

`make lint` runs the same checks as CI and needs the linters installed once:

```bash
make lint-tools   # ansible-lint, yamllint, shellcheck via uv; needs uv
```

## Scope

This repository must not publish environment details. Host addressing, LAN
CIDRs, and every secret live in gitignored `host_vars` and Ansible Vault, and the
per-cluster sealed manifests are gitignored too. CI and `make lint` only lint
and validate; neither touches a cluster.
