# Bring-up

Reproduces the dedicated host from a bare Ubuntu 26.04 install to a verified
testsight deployment. Run from a workstation that can reach the host over SSH.

## One command

Once the prerequisites below hold and the vault exists, `scripts/deploy.sh`
does steps 1 and 3-6 for you:

```bash
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/testsight/vault-pass
./scripts/deploy.sh --ip 192.168.8.201              # CIDR defaults to the /24
./scripts/deploy.sh --ip 10.0.0.50 --cidr 10.0.0.0/24 --skip-verify
```

It writes `ansible/host_vars/testsight/vars.yml` (backing up the previous copy),
runs `site.yml` twice, fetches the kubeconfig, bootstraps, and then runs
`verify.yml`, `backup-now` and `restore-test`. `--help` lists the flags.

Two things it deliberately does not do:

- **Create the vault.** `make secrets-init` is interactive, so the script stops
  if `ansible/group_vars/all/vault.yml` is missing. Create it once, back it up,
  and reuse it for every host.
- **Prepare the host.** The SSH key and passwordless sudo in Prerequisites are
  needed before the first run; there is no way to do that over Ansible alone
  when password auth may already be closed.

## Prerequisites

- Host: minimal Ubuntu 26.04, user `marek`, reachable on the LAN, with two
  preconditions that must hold **before** the first apply. Set them up in this
  order:

  1. Make sure the workstation has a keypair (`~/.ssh/id_ed25519` + `.pub`):

     ```bash
     ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)"   # skip if ~/.ssh/id_ed25519.pub exists
     ```

  2. Authorise its public half for `marek` on the host. This is the only step
     that needs the account password, so do it before anything hardens SSH:

     ```bash
     ssh-copy-id marek@<host-ip>
     ```

     If password login is already disabled on the host, append
     `~/.ssh/id_ed25519.pub` to `/home/marek/.ssh/authorized_keys` from the host
     console instead.

  3. Grant `marek` passwordless sudo for the provisioning run:

     ```bash
     echo "marek ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-testsight-provision
     sudo chmod 440 /etc/sudoers.d/90-testsight-provision
     ```

  4. Verify both preconditions from the workstation:

     ```bash
     ssh -o BatchMode=yes -o PasswordAuthentication=no marek@<host-ip> true  # key auth, no prompt
     ssh marek@<host-ip> 'sudo -n true'                                      # passwordless sudo
     ```

  Key auth is mandatory because the `ssh` role disables password and root login
  partway through the run. Passwordless sudo is mandatory because
  `ansible/ansible.cfg` sets `become_ask_pass = False`, so Ansible never prompts
  and instead fails with `sudo: interactive authentication is required`.

  Remove the sudoers file after the run if you do not want it permanent. Do not
  remove the key: the `ssh` role disables password and root login, so it becomes
  your only way in.

  The same public key also goes into `ssh_authorized_key` in step 1; the `ssh`
  role writes that value to the host and stops if it is not the key you actually
  connect with.

- Workstation: any Ubuntu with `python3`, `python3-venv`, `git`, `make`, `curl`,
  and `tar` (`apt-get install -y python3 python3-venv git make curl tar`).
  Everything else — `ansible-core`, `kubectl`, `helm`, `kubeseal`,
  `kubeconform`, and the `ansible.posix`/`community.general` collections — comes
  from `make install-tools`, which puts the binaries in `~/.local/bin` and
  ansible in a venv under `~/.local/share/testsight/ansible-venv`. Every `make`
  target prepends `~/.local/bin` to `PATH`, so no shell setup is needed.
- Run `make install-tools` before the remaining steps.

  For the linters (`make lint`), also run `make lint-tools`, which needs `uv`
  (`curl -LsSf https://astral.sh/uv/install.sh | sh`). Linters are installed as
  `uv tool`s on purpose: `ansible-lint` treats a virtualenv on `PATH` as a
  broken environment and prints a `PATH altered to include …` warning, while it
  recognises `.../uv/tools/...` as intentional.
- A read-only ed25519 deploy key on `github.com/markw77/testsight` and a GitHub
  classic personal access token named `testsight-infra-ghcr-read` with only the
  `read:packages` scope (note its expiry; another name breaks the checklist
  below).

## 1. Inventory

```bash
cp ansible/host_vars/testsight/vars.yml.example ansible/host_vars/testsight/vars.yml
```

Then set in `ansible/host_vars/testsight/vars.yml`:

- `testsight_host_ip` and `testsight_lan_cidr` (required),
- `ssh_authorized_key`: the workstation public key the `ssh` role installs and
  then validates before it disables password login (for example the contents of
  `~/.ssh/id_ed25519.pub`). Ansible itself keeps using your agent/default keys;
  this variable only controls what is written to the host,
- `postgres_db`, `postgres_user`, and optionally `backup_dir` and
  `backup_retention_days` (defaults live in `ansible/group_vars/all/vars.yml`).

`vars.yml` is gitignored and must stay uncommitted: this repository is public
and must not publish your LAN addressing or SSH keys.

`ansible/inventory/hosts.yml` does not hardcode the address. It templates
`ansible_host` from `testsight_host_ip` by reading this file with a lookup,
because ansible-core will not resolve a connection keyword from `host_vars`
itself. `ansible/playbooks/site.yml` and `verify.yml` also load `group_vars` and
`host_vars` explicitly through `vars_files`, for the same reason.

## 2. Secrets

```bash
make secrets-init          # creates ~/.config/testsight/vault-pass and vault.yml
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/testsight/vault-pass
```

`make secrets-init` generates:

- a random Postgres password and `BOOTSTRAP_API_KEY`,
- placeholder pgAdmin login (edit with `ansible-vault edit`),
- a new ed25519 deploy key under `~/.config/testsight/`,
- prompts for the pgAdmin email and password, and for the GitHub username and
  the `testsight-infra-ghcr-read` token as the GHCR pull credential.

### Register the deploy key before bootstrap

`make bootstrap` authenticates Argo CD to your app repo with this key. Register
it now:

```bash
cat ~/.config/testsight/testsight-infra-deploy-key.pub
```

Paste the output into `github.com/markw77/testsight` → Settings → Deploy keys →
Add deploy key, with "Allow write access" **unchecked** (read-only). Do this
before step 5; Argo cannot sync without it.

The private half is already inside the vault (`vault_argocd_repo_ssh_key`).
Argo CD's Helm values do not reference the key (`cluster-bootstrap/values/`); it
reaches Argo only through the `argocd-repo-testsight` Secret, which
`make bootstrap` seals and applies via `seal-secrets.sh`. No separate
`make seal` is needed at this step.

## 3. Check, apply, verify idempotence

Fresh host — apply directly, because check mode cannot resolve packages or
systemd units it is forbidden to create:

```bash
cd ansible
ansible-playbook playbooks/site.yml --syntax-check
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/site.yml                 # second run must be changed=0
ansible-playbook playbooks/verify.yml
```

Once the host is provisioned, use the dry run as a drift check:

```bash
make site-check     # syntax check + --check --diff, expect changed=0, failed=0
```

The two prerequisite checks must still pass here; re-run them as a smoke test
before the apply if the host was touched in between.

Expected results: the first apply reports a non-zero `changed`, the second
reports `changed=0`, and `verify.yml` finishes with `failed=0`. A non-`changed=0`
second run means something is not idempotent and is a bug worth fixing rather
than ignoring. `playbooks/verify.yml` asserts live state, so it only passes after
`site.yml` has converged.

On a fresh host `--check --diff` stops at the first task that depends on
something check mode never created — the Docker apt signing key or the
`testsight-docker-user.service` unit — so a non-zero exit there is expected, not
a bug. That is why step 3 applies directly and reserves `make site-check` for
drift detection once provisioned.

Role order is `base`, `ssh`, `docker`, `firewall`, `k3s`, `postgres`, `backup`.
The firewall runs after Docker so `DOCKER-USER` exists. Two ordering rules are
load-bearing:

- `ssh` writes `ssh_authorized_key` and verifies it landed before hardening, so
  a missing or wrong key stops the play instead of locking you out.
- `firewall` must stay after `docker`, otherwise the `DOCKER-USER` chain it
  rebuilds does not exist yet.

## 4. Kubeconfig

```bash
make kubeconfig   # ~/.kube/testsight-dedicated.yaml, mode 0600
export KUBECONFIG=~/.kube/testsight-dedicated.yaml
kubectl get nodes
```

`make kubeconfig` reads the host address from `testsight_host_ip` in
`ansible/host_vars/testsight/vars.yml` and rewrites the k3s loopback server
address to `https://<that-ip>:6443`, so no `~/.ssh/config` entry or DNS name is
needed. It SSHes as `marek@<that-ip>`; `TESTSIGHT_HOST` and `TESTSIGHT_HOST_IP`
override the target and address if you ever need them. Expect
`testsight Ready control-plane` with the pinned `K3S_VERSION`.

The export only affects the current shell. Add it to your profile, or prefix
later commands with `KUBECONFIG=~/.kube/testsight-dedicated.yaml`, and keep the
file out of the repo — it holds a cluster-admin certificate.

## 5. Bootstrap the cluster

```bash
make bootstrap
```

This installs Argo CD (pinned Helm chart) and Sealed Secrets (pinned upstream
release manifest — the project's old chart repository no longer exists), creates
namespaces, seals the repository and app Secrets, and applies the AppProject and
root Application. See `argocd.md` and `secrets.md`. The sealed manifests are
written into `cluster-bootstrap/secrets/`, which is gitignored: they are
per-cluster and regenerated by `make seal`.

The root-app wait is fatal — `bootstrap.sh` exits 1 and prints the Application's
conditions if it never reaches `Synced`, and warns separately if it is `Synced`
but not `Healthy`. `Synced` with no child Applications means
`deploy/argocd/apps` in the app repo is still empty.

### Argo CD UI

The UI is served on the LAN at `https://<host-ip>:8080` through k3s ServiceLB,
with a self-signed certificate. Only `testsight_lan_cidr` may reach it (`ufw`
plus `DOCKER-USER`).

Log in as `admin` with the password in the vault:

```bash
ANSIBLE_VAULT_PASSWORD_FILE=~/.config/testsight/vault-pass \
  ansible-vault view ansible/group_vars/all/vault.yml | grep argocd_admin
```

`install-argocd.sh` bcrypt-hashes that value into
`configs.secret.argocdServerAdminPassword`, so the chart's
`argocd-initial-admin-secret` never applies and is not the password to use.

To change it, generate a value and edit the vault:

```bash
openssl rand -base64 24 | tr -d '/+=' | head -c 28; echo
ANSIBLE_VAULT_PASSWORD_FILE=~/.config/testsight/vault-pass \
  ansible-vault edit ansible/group_vars/all/vault.yml
# set vault_argocd_admin_password to the generated value
```

Apply it with `make bootstrap`, which re-hashes the value and rolls
`argocd-server`. `make seal` does not carry this password — it lives in the Helm
release, not in a sealed Secret — so `make bootstrap` is the step that changes
it.

Avoid `ansible-vault view | grep` in a shared terminal: it prints the password
in the clear and leaves it in shell history. Use `ansible-vault edit` and read
the value in the editor when you only need to change it.

## 6. Verify

```bash
make verify        # sshd, ufw, listeners, 5432 blocked from a bridge,
                   # stacks healthy, node Ready, Traefik absent, timer active
make backup-now
make restore-test
```

Then follow the end-to-end checklist below.

## End-to-end checklist

- [ ] `ansible-playbook playbooks/site.yml --syntax-check` passes.
- [ ] `ansible-playbook playbooks/verify.yml` finishes with `failed=0`.
- [ ] Second apply reports `changed=0`.
- [ ] SSH password/root login disabled; only the workstation key works.

  `ssh -o PasswordAuthentication=no marek@<host-ip> true` succeeds, and with a
  password forced it fails (`ssh -o PubkeyAuthentication=no -o
  PasswordAuthentication=yes marek@<host-ip> true`). Repeat the key check
  **before** step 3 too, since the `ssh` role locks you out if the key is not
  authorised.

  On the host,
  `sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin|pubkeyauthentication)'`
  confirms the effective config; expect `no`, `no`, `yes`.
- [ ] UFW active; 80/443 closed; 22/6443 LAN-only; pgAdmin 5050 LAN-only.
- [ ] k3s pod/service networking works with UFW enabled.
- [ ] `5432` unreachable from a LAN client; k3s pods can reach it.

  `make verify` now proves the first half by opening a TCP connection to
  `5432` from a throwaway container on the default bridge — the same forwarded
  path a LAN client takes — and asserting it fails. It also asserts the
  `DOCKER-USER` fallback rules exist, because those cover established flows
  that kube-router's chain no longer sees.
- [ ] Docker and the Postgres/pgAdmin stack healthy.
- [ ] Backup timer fires; dump, checksum, and scratch restore pass.
- [ ] k3s Ready; Traefik absent; CoreDNS/local-path/metrics-server present.
- [ ] Argo CD and Sealed Secrets ready; repository credential works.
- [ ] Root and app Applications Synced/Healthy.
- [ ] Migration hook completes; `/readyz` database + migration head pass.
- [ ] Private GHCR images pull in both namespaces.
- [ ] Tunnel health/readiness/auth checks pass.
- [ ] Sync, async, stored-test, cancel, and Job/Secret cleanup pass.
- [ ] NetworkPolicy blocks metadata and private ranges.
- [ ] Empty database migrated to `0001_initial`; only bootstrap tenant and
      smoke rows exist.
- [ ] Digest promotion rolls the control plane; a Git revert rolls back.
- [ ] No plaintext secrets or dumps committed in either repo.
