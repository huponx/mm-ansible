# mm-ansible

Ansible code that builds and maintains the server: MicroK8s with its add-ons, ArgoCD, PostgreSQL and Redis.
It runs in **GitHub Actions**, which connects to the server over **SSH**. Secrets are stored with **ansible-vault**.

```mermaid
flowchart LR
  dev[Developer] -->|pull request| ci[CI workflow: lint + dry run]
  dev -->|merge to main| dep[Deploy workflow]
  ci -->|SSH| srv[(Server)]
  dep -->|SSH| srv
  vault[(ansible-vault files in git)] --> ci
  vault --> dep
  gh[GitHub secrets and variables] --> ci
  gh --> dep
```

## Contents

1. [Repository layout](#repository-layout)
2. [One-time setup](#one-time-setup)
3. [Ansible Vault](#ansible-vault)
4. [Day-to-day](#day-to-day) (including [one-shot options](#one-shot-options))
5. [PostgreSQL users and roles](#postgresql-users-and-roles)
6. [Redis](#redis)
7. [Kubernetes secrets](#kubernetes-secrets)
8. [Other roles](#other-roles)
9. [Troubleshooting](#troubleshooting)

## Repository layout

| Path | Purpose |
|---|---|
| `ansible.cfg` | Defaults: inventory, roles path, vault file, SSH pipelining |
| `requirements.txt` / `requirements.yml` | Pinned Python tools and Ansible collections |
| `inventories/production/hosts.ini` | Inventory. The address comes from `ANSIBLE_HOST` (not stored in git) |
| `inventories/production/group_vars/all/*.yml` | Variables. `*_vault.yml` files are encrypted |
| `playbooks/site.yml` | Everything: preflight, common, cluster, database, cache |
| `playbooks/{cluster,database,cache,common}.yml` | One part each, imported by `site.yml` |
| `roles/` | `microk8s`, `coredns`, `argocd`, `reloader`, `application-pvc`, `k8s-secrets`, `postgres`, `redis`, `vault`, `common`, `backup` |
| `.github/workflows/ci.yml` | Pull requests: lint, syntax check, then a dry run with diff of what the PR deploys (same tag plan as the deploy) |
| `.github/workflows/drift.yml` | Every Monday (and by hand): a full dry run, to see drift between the server and the repository |
| `.github/workflows/deploy.yml` | Push to `main` or manual run: deploy |
| `huponx/actions` `ansible-setup` | Shared setup action (lives in the `actions` repo, used as `@v1`): Python, collections, SSH, vault file |
| `Makefile` | Short commands, see `make help` |

Tags: `microk8s`, `coredns`, `argocd`, `reloader`, `pvc`, `secrets`, `vault`, `postgres`, `postgres_users`, `redis`, `common`, `backup`
(plus group tags `cluster`, `database`, `cache`).

## One-time setup

Do these steps once, in this order.

### 1. Server

Log in as a user with sudo and create a dedicated user for Ansible (named `ansible` here):

```bash
sudo adduser --disabled-password --gecos "" ansible
sudo install -d -m 700 -o ansible -g ansible /home/ansible/.ssh

# Passwordless sudo for this user (Ansible runs with become: true)
echo 'ansible ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/ansible
sudo chmod 440 /etc/sudoers.d/ansible
sudo visudo -cf /etc/sudoers.d/ansible
```

Allow SSH key login only (recommended): in `/etc/ssh/sshd_config.d/10-hardening.conf` set
`PasswordAuthentication no` and `PermitRootLogin no`, then `sudo systemctl reload ssh`.
Do this only after you have verified key login in step 3.

Network: the SSH port must be reachable from GitHub-hosted runners (public internet), or use a self-hosted runner.
Make sure the DNS name of the server resolves (and the extra names you use, for example the ArgoCD host).
`metallb_ip_range` in `inventories/production/group_vars/all/microk8s.yml` must be free addresses in your LAN.

### 2. Your machine

```bash
git clone <this repository> && cd mm-ansible
python3 -m venv .venv && . .venv/bin/activate
make deps                       # pip install -r requirements.txt + ansible-galaxy collection install

cp .env.example .env            # then edit: ANSIBLE_HOST, ANSIBLE_USER, ANSIBLE_SSH_PORT
printf '%s' 'a-long-random-passphrase' > .vault_pass && chmod 600 .vault_pass
```

`.env` and `.vault_pass` are gitignored. Keep the passphrase in a password manager: it is also needed in GitHub (step 4).

### 3. SSH key for CI

Create a key pair used **only** by GitHub Actions:

```bash
ssh-keygen -t ed25519 -f mm-ansible-deploy-key -N "" -C "mm-ansible-deploy"
```

This creates `mm-ansible-deploy-key` (private) and `mm-ansible-deploy-key.pub` (public) in the current directory on your machine.
The `ansible` user has no password (step 1), so `ssh-copy-id` cannot log in as it. Install the public key
with your own admin account instead:

```bash
scp mm-ansible-deploy-key.pub ADMIN_USER@YOUR_SERVER:/tmp/mm-ansible-deploy-key.pub
ssh ADMIN_USER@YOUR_SERVER
  sudo install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
  sudo sh -c 'cat /tmp/mm-ansible-deploy-key.pub >> /home/ansible/.ssh/authorized_keys'
  sudo chown ansible:ansible /home/ansible/.ssh/authorized_keys
  sudo chmod 600 /home/ansible/.ssh/authorized_keys
  rm /tmp/mm-ansible-deploy-key.pub
```

Only the public key goes to the server (appended to `/home/ansible/.ssh/authorized_keys`). Test it:

```bash
ssh -i mm-ansible-deploy-key ansible@YOUR_SERVER 'sudo -n true && echo OK'
```

Pin the server host key (do this from a network you trust, and compare the fingerprint with the server):

```bash
ssh-keyscan -t ed25519 -p 22 YOUR_SERVER > mm-ansible-known-hosts
ssh-keygen -lf mm-ansible-known-hosts                      # compare with: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub (on the server)
```

`mm-ansible-deploy-key`, `mm-ansible-deploy-key.pub` are gitignored. Delete the local private key after you store it in GitHub (step 4).

### 4. GitHub repository settings

Settings, Secrets and variables, Actions:

| Kind | Name | Value |
|---|---|---|
| Secret | `ANSIBLE_SSH_PRIVATE_KEY` | content of `mm-ansible-deploy-key` |
| Secret | `ANSIBLE_KNOWN_HOSTS` | content of `mm-ansible-known-hosts` |
| Secret | `ANSIBLE_VAULT_PASS` | the passphrase in `.vault_pass` |
| Secret | `BOT_TOKEN` | token of the bot that opens the [cleanup pull request](#one-shot-options) after a deploy (optional, see below) |
| Variable | `ANSIBLE_HOST` | server address, for example `server.example.com` |
| Variable | `ANSIBLE_USER` | `ansible` |
| Variable | `ANSIBLE_SSH_PORT` | `22` (optional, default 22) |

Or with the [GitHub CLI](https://cli.github.com/) (`gh auth login` first; run inside the repository or add `-R OWNER/REPO` to every command):

```bash
# Secrets (values are read from files, never typed on the command line)
gh secret set ANSIBLE_SSH_PRIVATE_KEY < mm-ansible-deploy-key
gh secret set ANSIBLE_KNOWN_HOSTS     < mm-ansible-known-hosts
gh secret set ANSIBLE_VAULT_PASS      < .vault_pass
gh secret set BOT_TOKEN                      # optional, paste the token when asked (see below)

# Variables
gh variable set ANSIBLE_HOST     --body "server.example.com"
gh variable set ANSIBLE_USER     --body "ansible"
gh variable set ANSIBLE_SSH_PORT --body "22"

# Check what is set (secret values are never shown)
gh secret list
gh variable list
```

Use the repository-level secrets above (the CI dry run job and the deploy job both read them).

`BOT_TOKEN` is optional. Without it the deploy still works; only the cleanup pull request (see [One-shot options](#one-shot-options)) is skipped, with a warning.
Why not the built-in `GITHUB_TOKEN`: a pull request opened with it does not start CI, so the required checks would never run.
Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) (or a GitHub App token) with:

- Repository access: only `huponx/mm-ansible`.
- Permissions: **Contents: Read and write**, **Pull requests: Read and write**. Nothing else.
- An expiry (for example 90 days). Rotate it before it expires and run `gh secret set BOT_TOKEN` again.
`.vault_pass` must contain the passphrase without a trailing newline problem: `printf '%s' '...' > .vault_pass` (as in step 2) is correct.

Then:

- **Settings, Environments, New environment** `production`: add **Required reviewers** so a deploy needs an approval.
- **Settings, Branches, protect** `main`: require a pull request and the status check **CI / lint and syntax**
(and **CI / dry run against the server** if you want the dry run to gate merges; a skipped dry run, when a PR only changes docs, counts as passed).

The same with `gh api` (replace `OWNER/REPO`, and `REVIEWER` with a GitHub username):

```bash
REPO=huponx/mm-ansible

# Environment `production` with a required reviewer
REVIEWER_ID=$(gh api users/REVIEWER --jq .id)
gh api -X PUT "repos/$REPO/environments/production" \
  --input - <<EOF
{ "reviewers": [ { "type": "User", "id": $REVIEWER_ID } ] }
EOF

# Merge settings
gh api -X PATCH "repos/$REPO" -F allow_squash_merge=true -F allow_merge_commit=false \
  -F allow_rebase_merge=false -F delete_branch_on_merge=true \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY

# Ruleset for `main`: PR required (squash only, 0 approvals so you can merge your own PR),
# required check `lint and syntax`, no force push, no deletion
cat > main-ruleset.json <<'JSON'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "lint and syntax" } ]
      }
    }
  ]
}
JSON
gh api "repos/$REPO/rulesets" --method POST --input main-ruleset.json
rm main-ruleset.json       # the file is only an input, do not commit it

# Check
gh api "repos/$REPO/environments/production" --jq '.protection_rules'
gh api "repos/$REPO/rulesets" --jq '.[] | {id, name, enforcement}'
```

Notes:

- Rulesets and required reviewers on private repositories need a paid GitHub plan (Pro, Team or Enterprise); public repositories have them for free.
- This is the same ruleset as `charts` and `mm-deploy` (PR required, squash only, strict required checks, no force push or deletion, repository admins bypass through a pull request). To change it later: `gh api repos/$REPO/rulesets/<id> --method PUT --input main-ruleset.json`.
- The status check name is the job name (`lint and syntax`). A check only appears in the list after it has run once, so open one pull request first.
- To run the deploy workflow by hand: `gh workflow run Deploy -f tags=postgres_users -f check_only=true`, then `gh run watch`.

### 5. Encrypt the vault files and make the first deploy

```bash
# edit the real secrets, then encrypt (skip files that are already encrypted: they start with $ANSIBLE_VAULT)
ansible-vault edit inventories/production/group_vars/all/postgres_vault.yml
ansible-vault edit inventories/production/group_vars/all/redis_vault.yml

make syntax
make check                      # dry run against the server, changes nothing
```

Run **Actions, Deploy, Run workflow** with `check_only` ticked, read the diff in the log, then run it again without it.
After the first run verify on the server:

```bash
pg_isready                      # accepting connections
redis-cli -a "$REDIS_PASSWORD" ping    # PONG
microk8s status --wait-ready
```

## Ansible Vault

Which files are encrypted:

| File | Contains |
|---|---|
| `inventories/production/group_vars/all/postgres_vault.yml` | `vault_postgres_user_passwords` (one entry per user) |
| `inventories/production/group_vars/all/redis_vault.yml` | `vault_redis_password` |
| `inventories/production/group_vars/all/argocd_vault.yml` | `vault_argocd_user_passwords` (one entry per ArgoCD user) and `vault_argocd_repo_secrets` (repository credentials), only the parts you use |
| `inventories/production/group_vars/all/k8s_secrets_vault.yml` | `vault_k8s_secrets` (values of the Kubernetes Secrets, see [Kubernetes secrets](#kubernetes-secrets)) |

Plain files only reference names, for example `postgres.yml` lists users, never passwords.
Rule: anything called `*_vault.yml` is encrypted before commit.
Check with `head -1 <file>`: it must print `$ANSIBLE_VAULT;1.1;AES256`.

```bash
ansible-vault create inventories/production/group_vars/all/new_vault.yml   # new encrypted file
ansible-vault encrypt <file>                                               # encrypt an existing plain file
ansible-vault edit <file>                                                  # decrypt, edit, re-encrypt
ansible-vault view <file>                                                  # read only
ansible-vault rekey <file>                                                 # change passphrase (see below)
make vault-edit F=postgres_vault.yml                                       # shortcut
```

The passphrase is read from `.vault_pass` locally and from `ANSIBLE_VAULT_PASS` in CI.

**Rotate the passphrase**

1. Write the new passphrase to `.vault_pass.new`.
2. `ansible-vault rekey --new-vault-password-file .vault_pass.new inventories/production/group_vars/all/*_vault.yml`
3. `mv .vault_pass.new .vault_pass`, update the GitHub secret `ANSIBLE_VAULT_PASS`, and commit the re-encrypted files in the same pull request.

   Do the secret update and the merge back to back: a deploy between them fails to decrypt.

**Never commit**: `.vault_pass`, `.env`, `mm-ansible-deploy-key`, decrypted vault files. If one is committed, treat the secret as leaked, rotate it and rewrite history.

**Lost passphrase**: encrypted files cannot be recovered. Recreate them with new secrets and change the matching passwords on the server
(set `rotate_password: true` for PostgreSQL users, run the redis role for the Redis password).

## Day-to-day

```bash
make check                          # dry run with diff, everything
make check TAGS=redis               # dry run, one component
make deploy TAGS=postgres_users     # apply one component
make deploy LIMIT=localserver       # one host
make lint                           # yamllint + ansible-lint
```

| In CI | Equivalent |
|---|---|
| Pull request | `make lint syntax`, then `make check TAGS=<tags of the PR>` (read-only); skipped when the PR only changes docs, CI or tooling |
| Merge to `main` | deploy workflow, only for what changed (below), after approval of the `production` environment |
| Manual run | **Actions, Deploy, Run workflow**: optional `tags`, `limit`, `check_only` (empty `tags` = everything) |
| Weekly | **Drift check**: full `make check`, summary in the run page |

**What a merge to `main` deploys.** The `plan` job of the deploy workflow (and of the pull request dry run, on the files of the PR) reads the changed files
([`.github/scripts/deploy-tags.sh`](.github/scripts/deploy-tags.sh)) and picks the tags:

| Changed files | Deploys |
|---|---|
| `roles/<role>/**` or `group_vars/all/<role>*.yml` of `microk8s`, `argocd`, `reloader`, `application-pvc` (tag `pvc`), `k8s-secrets` (tag `secrets`), `coredns`, `vault`, `postgres`, `redis`, `common`, `backup` | only the tags of those components, for example `argocd` |
| docs (`*.md`), `.github/**`, `scripts/**`, `Makefile`, lint configs, `requirements.txt`, `.env.example` | nothing: the deploy job and its approval are skipped |
| anything else (`playbooks/`, `inventories/**/hosts.ini`, `ansible.cfg`, `requirements.yml`, a new role) | everything |

So bumping `argocd_version` in `argocd.yml` deploys only `argocd`. **Actions, Deploy, Run workflow** always uses its own `tags` input (empty = everything).
A new component must be added to the script, otherwise a change to it falls into "everything".

A second run must report `changed=0`. If it does not, something is not idempotent: open an issue or fix the task.

### One-shot options

Some options are only meant for one run, for example `rotate_password: true`. Left in place they would repeat on every deploy.
After a successful deploy (not `check_only`) the workflow scans the files of the tags that ran, with
[`.github/scripts/cleanup-oneshot.py`](.github/scripts/cleanup-oneshot.py), and opens a pull request
`chore/cleanup-one-shot` that removes them (needs `BOT_TOKEN`). The run summary lists what was removed and what was kept, and why. Nothing is merged automatically. Merging that pull request does not start a deploy: the `plan` job skips a push whose commit title starts with `chore(ansible): remove one-shot options after deploy` (use squash or rebase merge and keep the title).

| Tag that ran | File scanned |
|---|---|
| `postgres`, `postgres_*`, or all | `postgres.yml` |
| `secrets`, or all | `k8s_secrets.yml` |
| `argocd`, or all | `argocd.yml` |
| `pvc`, or all | `pvc.yml` |

| Removed | Notes |
|---|---|
| `rotate_password`, `recreate`, `force`, `keys_absent`, `revoke_roles` | kept when the log has `Login check failed for <user>`, so the password change can be retried |
| `postgres_rotate_passwords`, `postgres_allow_drop_databases` | set back to `false` |
| `application_pvcs_absent` (in `pvc.yml`) | emptied to `[]` once the claims were deleted |
| whole list items with `state: absent` | a database is removed only when `postgres_allow_drop_databases: true` was set |

`*_vault.yml` files are never opened. Test the script with `bash .github/scripts/tests/run.sh` (runs in CI too).

**Roll back**: revert the pull request and merge it, the deploy applies the previous state.
Packages and database content are not reverted by Ansible: restore from backups when needed (see the `backup` role below).

**Upgrade ArgoCD** by changing `argocd_version` in `inventories/production/group_vars/all/argocd.yml` (pinned, default in the role).

## PostgreSQL users and roles

`inventories/production/group_vars/all/postgres.yml` is the source of truth; every run makes the server match it.
Passwords are in `postgres_vault.yml` under `vault_postgres_user_passwords`, keyed by user name.

### Add a user

1. Add the password:
   ```bash
     ansible-vault edit inventories/production/group_vars/all/postgres_vault.yml
   ```
2. Declare the user in `postgres.yml`:
   ```yaml
     postgres_users:
       - name: reports-ro
         databases:
           - name: data
             priv: SELECT                   # ALL | SELECT | INSERT | UPDATE | DELETE (comma separated)
   ```
3. Apply: `make deploy TAGS=postgres_users` (or merge to `main`).

What it does: creates the login, creates the database if it does not exist (owner = first user that references it, or `postgres_databases`),
grants `CONNECT` and `USAGE`, grants the privileges on existing tables and sequences, and sets **default privileges** so tables created later by migrations
are usable too. Privileges that are no longer wanted are revoked, so changing `ALL` to `SELECT` really removes write access.

### Use group roles

Grant privileges once to a group role and add users as members:

```yaml
postgres_roles:
  - name: data_readonly
    databases:
      - { name: data, priv: SELECT }

postgres_users:
  - name: reports-ro
    roles: [data_readonly]
    databases: []
```

Remove a membership with `revoke_roles: [data_readonly]`.

### Change privileges, limits or the password

- Privileges: change `priv` and apply.
- Limits: `attrs: { connection_limit: 20, valid_until: "2027-01-01", role_attr_flags: "CREATEDB" }`.
- Password: edit the value in `postgres_vault.yml`, set `rotate_password: true` on the user, apply, then remove the flag.
Without the flag, an existing user's password is never overwritten. (`postgres_rotate_passwords: true` rotates every user.)
If a vault password does not match the server, the run prints a warning ("Login check failed").

### Remove a user

```yaml
postgres_users:
  - name: reports-ro
    state: absent
```

Apply. The user's objects are reassigned to `postgres`, its privileges are dropped, then the role is dropped. The database is **not** dropped.
You can delete the vault entry afterwards.

### Remove a database (data loss)

```yaml
postgres_databases:
  - name: old_db
    state: absent
```

This only prints a notice unless you also set `postgres_allow_drop_databases: true` for that run.

### Server roles that are not in the file

`postgres_prune_unmanaged` (default `report`) lists roles on the server that are not defined here.
`delete` drops them (after reassigning their objects), `off` ignores them. `postgres` and `pg_*` roles are always protected
(`postgres_protected_roles`).

### Verify

```bash
sudo -u postgres psql -c '\du'                 # roles and members
sudo -u postgres psql -d data -c '\dp'        # table privileges
sudo -u postgres psql -d data -c '\ddp'       # default privileges
PGPASSWORD=... psql -h SERVER -U reports-ro -d data -c 'select 1'
```

`make check TAGS=postgres_users` shows the planned changes first.

PostgreSQL access from outside the host comes from `postgres_allowed_cidrs` (default `10.1.0.0/16`) with `postgres_auth_method: scram-sha-256`.
If a password was stored as an md5 hash before, set `postgres_auth_method: md5` or rotate that password.

### ArgoCD users

The built-in `admin` account is not managed by Ansible (its first password is in the secret
`argocd-initial-admin-secret`). Extra local accounts are listed in
`inventories/production/group_vars/all/argocd.yml`:

```yaml
argocd_users:
  - name: hung
    role: admin          # admin | readonly | a role you define in argocd_rbac_extra_policy
    apikey: false        # true lets the account create API tokens
  - name: old-user
    state: absent        # removes the account and its password
```

Roles you can give a user (the `role` field):

| Role | Can do |
|---|---|
| `admin` | everything: manage applications, projects, repositories, clusters, settings |
| `readonly` | view applications and projects, no changes (also the default for accounts without a role) |
| your own | any role defined in `argocd_rbac_extra_policy`, for example `deployer` below |

```yaml
argocd_rbac_extra_policy: |
  p, role:deployer, applications, get, */*, allow
  p, role:deployer, applications, sync, */*, allow
```

With that, `role: deployer` on a user lets them view and sync applications but not edit or delete them.
Policy syntax: [ArgoCD RBAC](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/).

Passwords go in `argocd_vault.yml` (create it, then encrypt):

```bash
cat > inventories/production/group_vars/all/argocd_vault.yml <<'EOF'
vault_argocd_user_passwords:
  hung: "a-long-random-password"
EOF
make vault-encrypt F=argocd_vault.yml
make deploy TAGS=argocd
```

- ArgoCD cannot switch off "change my password" in its UI or CLI. Ansible is the source of truth instead: with `argocd_enforce_passwords: true` (default) every run compares the stored hash with the vault password and puts the vault one back when they differ. A password changed in the UI therefore lasts until the next deploy, and that user is signed out when it is reverted. Set `argocd_enforce_passwords: false` to only set the password of accounts that have none.
- To change a password on purpose, edit the vault file and deploy (with enforcement on, nothing else is needed; with it off, also set `rotate_password: true` on the user once). A deploy that changes nothing does not touch the passwords or sign anyone out.
- `policy.csv` of `argocd-rbac-cm` is managed from `argocd_users` (`g, <user>, role:<role>` lines) plus `argocd_rbac_extra_policy`; manual edits to it are overwritten while `argocd_users` is not empty. `argocd_rbac_default_policy` (default `role:readonly`) applies to everyone else.
- The `password_hash('bcrypt')` filter needs `passlib` and `bcrypt` on the machine that runs Ansible (in `requirements.txt`, so `make deps` installs them).

#### ArgoCD API tokens

An account with `apikey: true` can have an API token that a service uses (gatekeeper reads the applications with one for the system status card of the admin app). `argocd_api_tokens` generates it once and stores it in a Kubernetes Secret:

```yaml
argocd_users:
  - { name: gatekeeper, role: status-reader, apikey: true }   # password: vault_argocd_user_passwords.gatekeeper
argocd_rbac_extra_policy: |
  p, role:status-reader, applications, get, */*, allow
  p, role:status-reader, accounts, update, gatekeeper, allow     # an account creates its own token with this
argocd_api_tokens:
  - account: gatekeeper
    secret_name: gatekeeper-argocd      # mm-deploy gatekeeper.yaml: GATEKEEPER_ARGOCD_TOKEN <- key token
    secret_namespace: application
    # secret_key: token                 # default
    # expires_in: 8760h                 # default: no expiry
    # rotate: true                      # new token, then remove the flag
```

- Run `make deploy TAGS=argocd`. (The ingress setup runs ArgoCD with `server.insecure`, so the CLI in the pod uses `--plaintext`.) The account signs in inside the `argocd-server` pod (no ingress, no admin password), so the only secret needed is its password in the vault. The password is read from stdin and the token is applied from stdin (server side), so neither shows in a command line, a log or an annotation.
- Idempotent: when the Secret already holds the key, nothing is generated, so a run never breaks a working token. `rotate: true` replaces it (restart of gatekeeper follows by itself, Reloader watches the Secret).
- The role only reads applications. If the account cannot create its token, check the `accounts, update` line (policy syntax of the ArgoCD version in `argocd_version`).

### ArgoCD repositories and root applications

ArgoCD reads a Git repository from a Secret in the `argocd` namespace. The role creates them from
`inventories/production/group_vars/all/argocd.yml`:

```yaml
argocd_repositories:
  - name: mm-deploy
    url: https://github.com/huponx/mm-deploy.git
    auth: token                  # none | token | ssh
    secret: shared-token         # optional: vault key to use instead of `name`
  - name: ghcr-charts            # Helm charts in GHCR: the Helm repository form with Enable OCI
    type: helm
    oci: true
    url: ghcr.io/huponx/charts   # no oci:// prefix
    auth: token
    secret: ghcr-read            # a classic PAT with read:packages
  - name: old
    url: https://github.com/huponx/old.git
    state: absent                # removes the Secret

# One credential for every repository whose URL starts with the prefix (no per-repository secret)
argocd_repo_credentials:
  - name: huponx
    url: https://github.com/huponx
    auth: token

# An Application that reads a directory of Application manifests (app of apps)
argocd_root_apps:
  - name: root-production
    repo_url: https://github.com/huponx/mm-deploy.git
    path: applications/production
    recurse: false               # also read sub-directories
    automated: true              # sync by itself (default)
    prune: false                 # delete what is removed from git (default false)
    cascade_delete: true         # finalizer: deleting the root deletes its children (default)
```

Credentials are never in `argocd.yml`. They go in `argocd_vault.yml`, keyed by the `name` above:

```yaml
vault_argocd_repo_secrets:
  mm-deploy:                     # auth: token
    username: huponx
    password: "github_pat_..."
  huponx:                        # a repo-creds entry
    username: huponx
    password: "github_pat_..."
  my-ssh:                        # auth: ssh
    ssh_private_key: |
      -----BEGIN OPENSSH PRIVATE KEY-----
      ...
      -----END OPENSSH PRIVATE KEY-----
```

The vault key is the `name` of the entry, or its `secret` field when set. To share one token between several
entries, give them the same `secret` (one vault entry, many repositories):

```yaml
argocd_repositories:
  - { name: mm-deploy, url: "https://github.com/huponx/mm-deploy.git", auth: token, secret: huponx-token }
  - { name: mm-deploy-2, url: "https://github.com/huponx/other.git",   auth: token, secret: huponx-token }
```

```yaml
# argocd_vault.yml
vault_argocd_repo_secrets:
  huponx-token:
    username: huponx
    password: "github_pat_..."
```

For every repository under one owner, `argocd_repo_credentials` (URL prefix) is shorter still: one entry, no
`auth` on the repositories.

Then `make vault-edit F=argocd_vault.yml` (or `vault-encrypt` for a new file) and `make deploy TAGS=argocd`.

#### Private GHCR: charts and images

The Applications of `mm-deploy` use `repoURL: oci://ghcr.io/huponx/charts/<name>`: Helm charts in GHCR, not a
Git repository (the `huponx/charts` repository is only their source and ArgoCD never reads it). Three things
can be private, and each has its own credential:

| What | Who reads it | Credential | Setting |
|---|---|---|---|
| `mm-deploy` Git repository | ArgoCD | fine-grained PAT, `Contents: Read-only` on `mm-deploy` | `argocd_repositories` entry, `auth: token` |
| Helm charts `ghcr.io/huponx/charts/*` | ArgoCD | **classic** PAT, scope `read:packages` | one `argocd_repositories` entry with `type: helm`, `oci: true` and `url: ghcr.io/huponx/charts` |
| Images `ghcr.io/huponx/*` | kubelet of the cluster | the same kind of classic PAT | `argocd_image_pull_secrets` |

This version of ArgoCD offers only the types `git` and `helm` (with *Enable OCI*) in Settings, Repositories, so OCI
charts are registered as one Helm repository (`ghcr.io/huponx/charts`, no `oci://`). That entry matches an
Application written in the Helm form:

```yaml
source:
  repoURL: ghcr.io/huponx/charts   # no oci://
  chart: courier                   # instead of path: .
  targetRevision: "1.2.3"
```

An Application with `repoURL: oci://ghcr.io/huponx/charts/courier` and `path: .` (the OCI source form) is not matched
by it: ArgoCD treats that URL as Git and fails with `unsupported scheme "oci"`. Either write the Applications in the
Helm form, or upgrade ArgoCD (`argocd_version`) to a release that has the repository type `oci`, then add one
`type: oci` repository per chart URL (`oci://ghcr.io/huponx/charts/<name>`).

Fine-grained PATs do not work with GHCR. Public packages need none of the last two. Use a classic PAT dedicated to
`read:packages` (for example `ghcr-prod-pull-2027-11`), never one that also has `repo`.

```yaml
# argocd.yml
argocd_image_pull_secrets:
  - name: ghcr-pull
    namespace: application       # created if missing
    # registry: ghcr.io          # default
    # service_account: default   # default: the secret is added to this ServiceAccount, so Pods need no imagePullSecrets
    secret: ghcr-read            # vault key (default: name)
```

```yaml
# argocd_vault.yml
vault_argocd_repo_secrets:
  ghcr-read:
    username: huponx
    password: "ghp_..."          # classic PAT with read:packages
```

The secret is added to the `default` ServiceAccount, which covers the apps that do not create their own. The services
that create their own ServiceAccount (`courier`, `identity`, `gatekeeper`: `serviceAccount.create: true`) get it
from the chart instead, since the ServiceAccount only exists after ArgoCD has synced the app. The charts
`go-application` >= 1.2.0, `web-application`, `python-application`, `go-job` and `migration-job` >= 1.1.0 accept
`imagePullSecrets` (`deployment.imagePullSecrets`, `job.imagePullSecrets` or the top-level `imagePullSecrets` of
`migration-job`), for example in the Application of `mm-deploy`:

```yaml
valuesObject:
  deployment:
    imagePullSecrets:
      - name: ghcr-pull
```

Set `service_account: none` on the entry when only the charts reference the secret (no ServiceAccount is patched).
`state: absent` removes the secret.

HTTPS token or SSH deploy key for a private repository:

| | HTTPS + token (PAT) | SSH deploy key |
|---|---|---|
| Scope | a fine-grained PAT can be limited to chosen repositories, read-only (`Contents: read`) | one key per repository, read-only by default |
| One credential for many repositories | yes (`argocd_repo_credentials` with a URL prefix, one PAT) | no: GitHub allows a deploy key on only one repository |
| Expiry | fine-grained PATs expire (max 1 year): you must renew | does not expire |
| Tied to a person | yes, the token acts as its owner (use a machine user if you can) | no, it belongs to the repository |
| Setup | create the PAT, put it in the vault | `ssh-keygen`, add the public key in the repository settings, put the private key in the vault |
| Firewall | port 443 | port 22 must be open |

A PAT with one `argocd_repo_credentials` entry is the shortest for several private repositories; deploy keys fit
best when you want a key that cannot read anything else. Use `https://` URLs with tokens and `git@github.com:owner/repo.git` with SSH keys.
Public repositories need no credential: list them without `auth`.

Using a token on a public repository also works (it raises the GitHub rate limit), but an expired or revoked
token makes GitHub answer 401 even for public repositories, so the sync stops. Prefer no `auth` for public
repositories, or one `argocd_repo_credentials` prefix entry and a renewal date for the token.

Permissions the PAT needs (ArgoCD only clones and fetches, so read-only is enough):

| PAT type | Settings |
|---|---|
| Fine-grained (recommended) | Resource owner: the owner of the repositories (for an organization, an admin must allow fine-grained PATs). Repository access: *Only select repositories*, pick the ones ArgoCD reads. Repository permissions: **Contents: Read-only** (`Metadata: Read-only` is added automatically). Nothing else. Set an expiry and note the renewal date. |
| Classic | Scope `repo` (the only scope that reads private repositories; it also gives write access, so prefer fine-grained). Add `read:org` or authorize SSO only if the organization requires it. |

- The `username` can be any non-empty string for a PAT, but use the account name.
- A fine-grained PAT with *All repositories* would also work with one `argocd_repo_credentials` prefix, at the cost of a wider scope.
- For an SSO-enforced organization, authorize the token for that organization after creating it.
- To rotate: edit `argocd_vault.yml` with the new token and run `make deploy TAGS=argocd`.
- Name the token `<system>-<environment>-<access>-<expiry>`, for example `argocd-prod-readonly-2027-11`, one token per
  environment, and put the owner and purpose in its description. The vault key can use the same name
  (`secret: argocd-prod-readonly`).

The root `infra-production` applies the plain manifests of mm-deploy `infra-services/production/` (namespace `infrastructure`, the ExternalName Services for PostgreSQL and Redis; the gatekeeper routes are rendered by the gatekeeper chart, not here). Each environment is its own directory (`infra-services/<env>/`) and its own cluster; the root uses `prune: false`. Needs `make deploy TAGS=argocd`.

What `prune`, `recurse` and `cascade_delete` do on a root application:

| Field | Default | Meaning |
|---|---|---|
| `automated` | `true` | ArgoCD syncs by itself; with `false` you sync by hand |
| `prune` | `false` | With `true`, a manifest removed from git is deleted from the cluster; with `false` it only shows as OutOfSync |
| `self_heal` | `true` | Undoes manual changes made in the cluster |
| `recurse` | `false` | With `true`, sub-directories of `path` are read too (every YAML file in them is applied) |
| `include`, `exclude` | unset | Glob (relative to `path`) of the files read or skipped, for example `"{namespace.yaml,redis/*.yaml}"` |
| `dest_namespace` | `argocd` | Namespace for manifests that do not set one |
| `cascade_delete` | `true` | Finalizer: deleting the root also deletes its child Applications |

- Secrets are applied with server-side apply and sent on stdin, so the secret is not left in a `last-applied` annotation or in the process list.
- A root Application has the `resources-finalizer.argocd.argoproj.io` finalizer by default (`cascade_delete: true`): deleting it (`state: absent`) deletes the child Applications, and their resources too if each child also has the finalizer. Set `cascade_delete: false` to keep them.

## Redis

| Variable | Default | Description |
|---|---|---|
| `redis_port` | `6379` | Port |
| `redis_bind` | `0.0.0.0` | Interfaces. Prefer the private address of the server |
| `redis_require_password` | `true` | Sets `requirepass`; needs `vault_redis_password` |
| `redis_upgrade` | `false` | Upgrade the package on every run |
| `redis_maxmemory`, `redis_maxmemory_policy` | empty, `noeviction` | Optional memory limit |

Password: `ansible-vault edit inventories/production/group_vars/all/redis_vault.yml`, set `vault_redis_password`, then `make deploy TAGS=redis`.
The role checks `redis-cli ping` at the end.

## Kubernetes secrets

Tag `secrets` (role `k8s-secrets`) creates, updates, patches and deletes Secrets in any namespace.
Only the Secrets listed in `k8s_secrets` are touched: a Secret that is not listed is never pruned.
The list is in `inventories/production/group_vars/all/k8s_secrets.yml`, the values in the encrypted `k8s_secrets_vault.yml`.

```yaml
# k8s_secrets.yml
k8s_secrets:
  - name: app-env
    namespace: application
    mode: replace                  # only DB_PASSWORD and API_KEY remain; other keys are removed
    secret: application-app-env    # vault key (default: <namespace>-<name>)
  - name: shared
    namespace: application
    mode: merge                    # add or change the declared keys, keep the others
    keys_absent: [OLD_KEY]         # delete these keys
  - name: legacy
    namespace: application
    state: absent                  # delete the Secret
```

```yaml
# k8s_secrets_vault.yml  (make vault-encrypt F=k8s_secrets_vault.yml)
vault_k8s_secrets:
  application-app-env:
    DB_PASSWORD: "change-me"
    API_KEY: "change-me"
```

| Field | Default | Meaning |
|---|---|---|
| `name`, `namespace` | required | The namespace is created when it does not exist (not for `state: absent`) |
| `type` | `Opaque` | Also `kubernetes.io/tls`, `kubernetes.io/dockerconfigjson`, ... The type of a Secret is immutable: when it differs from the cluster the run fails, unless `recreate: true` (delete, then create) |
| `mode` | `replace` | `replace`: exactly the declared keys remain. `merge`: only the declared keys are set, the other keys stay |
| `keys_absent` | `[]` | `merge` only: keys to delete |
| `state` | `present` | `absent` deletes the Secret |
| `force` | `false` | Allow deleting a Secret that this role did not create |
| `secret` | `<namespace>-<name>` | Key in `vault_k8s_secrets` |

- Every Secret written by the role has the label `app.kubernetes.io/managed-by: mm-ansible`. `state: absent` deletes only Secrets with that label (an existing Secret gets it the first time it is listed as `present`), otherwise it fails unless `force: true`.
- `kube-system` and the ArgoCD internal secrets (`argocd-secret`, `argocd-initial-admin-secret`, `repo-*`, `creds-*`) cannot be managed here; use the `argocd` role for repositories and pull secrets.
- Values are sent on stdin with server-side apply, a JSON patch or a merge patch, so they are not in a `last-applied` annotation, the process list or the Ansible output (`no_log`). A second run reports `changed=0` when nothing differs.
- `make check TAGS=secrets` lists, by name and key names only, which Secrets would be created, updated or deleted.
- To delete a Secret: set `state: absent` on its entry, deploy, then remove the entry and its vault values in a later change.
- Pods do not see a changed Secret value until they restart; the `reloader` role can restart workloads annotated for it.

### Identity and gatekeeper secrets

These Secrets cannot live in `mm-deploy` (its policy forbids Secrets with data and secret literals), so they are created here from the vault. Add the values to `k8s_secrets_vault.yml` **before** the entries in `k8s_secrets.yml` are deployed, otherwise the `secrets` run fails on the missing vault key.

| Secret (namespace `application`) | Key | Value | Used by |
|---|---|---|---|
| `identity-signing-key` | `signing.pem` | EC P-256 PEM private key | identity (mounted read-only at `/var/run/identity/keys/`), `IDENTITY_SIGNING_KEY_ID` in mm-deploy is its `kid` |
| `identity-mfa-key` | `keys` | `k1:<base64 of 32 bytes>` | identity `IDENTITY_MFA_KEY`, seals the TOTP secrets |
| `gatekeeper-session` | `keys` | `k1:<base64 of 32 bytes>` | gatekeeper `GATEKEEPER_SESSION_KEY`, seals the tokens kept in Redis |
| `gatekeeper-client` | `secret` | random string, e.g. 32 random bytes (generated by `make identity-secrets`) | gatekeeper `GATEKEEPER_CLIENT_SECRET`; the identity setup Job stores its hash on the `gatekeeper` client |
| `dictionary-client` | `secret` | random string (generated by `make identity-secrets`) | dictionary `DICTIONARY_CLIENT_SECRET`; the identity setup Job stores its hash on the `dictionary` client |
| `courier-client` | `secret` | random string (generated by `make identity-secrets`) | courier `IDENTITY_CLIENT_SECRET`; the identity setup Job stores its hash on the `courier` client |
| `courier-vapid` | `private-key` | the private VAPID key of Web Push (generated by `make vapid-keys`, make it once; the public key is printed in the comment line and goes in `VAPID_PUBLIC_KEY` of the courier and courier-worker Applications) | courier-worker `VAPID_PRIVATE_KEY` |
| `identity-admin` | `password` | random temporary password (generated by `make identity-secrets`) | identity setup Job `SETUP_ADMIN_PASSWORD`: creates the first admin, who must change it at the first sign in |

```bash
make identity-secrets                      # generates all of them; copies the YAML to the clipboard on macOS (else prints it)
make vault-edit F=k8s_secrets_vault.yml    # paste under vault_k8s_secrets:, save
make deploy TAGS=secrets                   # or merge to main
```

`scripts/gen-identity-secrets.sh` writes nothing to disk. The vault block looks like this (the PEM is a block scalar):

```yaml
vault_k8s_secrets:
  application-identity-signing-key:
    signing.pem: |
      -----BEGIN EC PRIVATE KEY-----
      ...
      -----END EC PRIVATE KEY-----
  application-identity-mfa-key:
    keys: "k1:..."
  application-gatekeeper-session:
    keys: "k1:..."
  application-gatekeeper-client:
    secret: "..."
  application-dictionary-client:
    secret: "..."
  application-courier-client:
    secret: "..."
  application-courier-vapid:
    private-key: "..."     # from `make vapid-keys` (apart from identity-secrets: make it once, a new pair breaks every subscription)
  application-identity-admin:
    password: "..."        # temporary; remove it after the first admin signed in and changed it
```

Keep these values in the vault: losing `identity-mfa-key` makes every enrolled authenticator useless, losing `identity-signing-key` stops every issued token from verifying, losing `gatekeeper-session` only logs the web users out.

**Rotation**
- `gatekeeper-session` and `identity-mfa-key`: prepend the new key, keep the old one: `keys: "k2:<new>,k1:<old>"` (the first seals, the others only open). Remove `k1` later.
- `identity-signing-key`: put the old PEM in a Secret `identity-previous-keys` as `<old kid>.pem` (add it as another entry here with its vault values), replace `signing.pem` in the vault, set a new `IDENTITY_SIGNING_KEY_ID` in the identity Application of mm-deploy, deploy both. Remove the previous key after the longest access token lifetime (10 minutes by default). Details in the identity README.
- `gatekeeper-client`: rotate with the admin app (Clients, rotate secret), put the new value in the vault, `make deploy TAGS=secrets`. (While the identity setup Job is still deployed it would reset the secret to the vault value at its next sync, so remove the Job first.)
- `identity-admin`: used once. After the first admin signed in and changed the password, remove the setup Job from the identity Application in mm-deploy, then delete the entry and the vault value (`state: absent`, deploy, remove the entry).
- After any change the pods need to restart; workloads of `go-application` carry the Reloader annotation, so the `reloader` role restarts them.

## CoreDNS hosts

Tag `coredns` adds names to the cluster DNS, so pods resolve servers that live outside Kubernetes.
mm-deploy `infra-services` has `ExternalName` Services (`postgres-external`, `redis-external`) that point to
`postgres.my-network.local` and `redis.my-network.local`; CoreDNS must know those names.

```yaml
# inventories/production/group_vars/all/coredns.yml
coredns_hosts:
  - ip: 192.168.0.201
    names: [postgres.my-network.local, redis.my-network.local]
```

`make deploy TAGS=coredns` writes one `hosts { ... fallthrough }` block, between the comments `# BEGIN mm-ansible hosts` and `# END mm-ansible hosts`,
at the top of the `.:53 { }` block of `kube-system/coredns`, then restarts CoreDNS only when the Corefile changed. The rest of the Corefile is not touched;
an empty list removes the block. Re-enabling the MicroK8s `dns` add-on resets the ConfigMap: run the tag again. Test from a pod: `nslookup postgres.my-network.local`.

## Other roles

| Role | Purpose | Main variables |
|---|---|---|
| `microk8s` | Install MicroK8s, enable the add-ons in `microk8s_addons`, cert-manager issuer | `microk8s_version`, `metallb_ip_range`, `microk8s_addons`, `acme_email`, `cluster_issuer_name` |
| `argocd` | Install ArgoCD (pinned manifest), its ingress, optional local users (`argocd_users`), repositories and root applications | `argocd_version`, `argocd_ingress_host`, `argocd_external_url` |
| `coredns` | Static host names in the CoreDNS Corefile (for example the external PostgreSQL and Redis behind the mm-deploy `ExternalName` Services), then a CoreDNS restart | `coredns_hosts` |
| `reloader` | Stakater Reloader (Helm) | `reloader_chart_version` |
| `application-pvc` | PersistentVolumeClaims for applications: the list `application_pvcs` (`application-pvc` 1Gi and `dictionary-files` 5Gi, the image and audio store the dictionary chart mounts). They live outside ArgoCD, so deleting an Application keeps the data; run tag `pvc` before the first deploy, or the pod stays `Pending`. ReadWriteOnce hostpath only works on a one-node cluster | `application_pvcs` (`name`, `namespace`, `storage`, `storage_class`, `access_modes`), `application_pvcs_absent` (names to delete) |
| `k8s-secrets` | Create, replace, merge-patch and delete Kubernetes Secrets | `k8s_secrets`, `vault_k8s_secrets` |
| `vault` | HashiCorp Vault and External Secrets Operator. Off unless `vault_enabled: true` | `vault_ingress_host`, `vault_dev_mode`, `eso_chart_version` |
| `common` | Optional: unattended upgrades, fail2ban, UFW. Off unless `common_enabled: true` | `common_ufw_enabled`, `common_ufw_rules` |
| `backup` | Optional: daily PostgreSQL dumps and Redis RDB copy via a systemd timer. Off unless `backup_enabled: true` | `backup_dir`, `backup_keep_days`, `backup_schedule`, `backup_pvc_enabled`, `backup_pvc_path` |

Before enabling the firewall (`common_ufw_enabled: true`) make sure the SSH port and the cluster ports you use are in `common_ufw_rules`.
Backups are stored on the same server: copy `backup_dir` somewhere else for real disaster recovery.
With `backup_pvc_enabled: true` and `backup_pvc_path` (the hostpath directory of the `dictionary-files` PV) the script also writes `dictionary-files-<stamp>.tar.gz`; the same `backup_keep_days` applies.
Replacing a PVC (for example `dictionary-images` by `dictionary-files`): the name of a claim cannot change, so create the new one and delete the old one in this order. (1) Run `--tags pvc` with the new claim in `application_pvcs`. (2) Deploy the chart that mounts it and check that the pods run. (3) Set `application_pvcs_absent: [dictionary-images]` in `inventories/production/group_vars/all/pvc.yml` (or `<namespace>/<name>`; the default namespace is `pvc_default_namespace`) and run `--tags pvc` again: it runs `kubectl delete pvc --ignore-not-found` for the names listed and nothing else. A claim a pod still mounts stays `Terminating` until the pod is gone, so do it after the rollout. With the `Delete` reclaim policy of `microk8s-hostpath` the PV and its directory are deleted with the claim (check with `microk8s kubectl get sc microk8s-hostpath -o jsonpath='{.reclaimPolicy}'`; with `Retain` delete the PV and the directory by hand). (4) `application_pvcs_absent` is emptied again by the cleanup pull request after the deploy (see One-shot options).
Restore a database with `pg_restore -d data --clean /var/backups/mm/postgres-data-<stamp>.dump`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Host key verification failed` | `ANSIBLE_KNOWN_HOSTS` is wrong or the server was rebuilt. Re-scan from a trusted network, compare the fingerprint, update the secret. |
| `Permission denied (publickey)` | The CI public key is not in `/home/ansible/.ssh/authorized_keys`, or `ANSIBLE_USER` is wrong. Test with `ssh -i mm-ansible-deploy-key ansible@HOST`. |
| `Decryption failed` / `vault password file was not found` | Wrong `ANSIBLE_VAULT_PASS` or `.vault_pass`. Check with `ansible-vault view <file>`. |
| `sudo: a password is required` | The sudoers rule is missing. Redo step 1. The preflight play reports this first. |
| `Could not get lock /var/lib/dpkg/lock` | `unattended-upgrades` is running. Wait and re-run. |
| `Missing ANSIBLE_HOST variable ...` in the workflow | Variable or secret not set, or set on another environment. See step 4. |
| `Invalid PostgreSQL configuration` | The assert lists the rules: names with letters, digits, `_`, `-`; no protected or `pg_*` role; every present user has a vault password; owners are managed users. |
| `kubectl`/`microk8s` permission errors | The user must be in the `microk8s` group (the role adds it; log in again). |
| Dry run shows tasks as changed that are not | `--check` cannot predict commands that depend on earlier changes. Compare with a real second run (`changed=0`). |
