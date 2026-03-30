# x-ansible

## Roles

| Role | Purpose |
|---|---|
| `install-postgres` | Install and configure PostgreSQL on Ubuntu via apt |
| `redis` | Install and configure Redis on Ubuntu via apt |
| `argocd` | Deploy ArgoCD to a Kubernetes cluster |
| `microk8s` | Install and configure MicroK8s |
| `vault` | Deploy HashiCorp Vault and External Secrets Operator |
| `reloader` | Deploy Stakater Reloader |
| `application-pvc` | Manage PersistentVolumeClaims for applications |

---

## install-postgres

### Role variables

| Variable | Default | Description |
|---|---|---|
| `postgres_version` | `"16"` | PostgreSQL major version to install |
| `postgres_port` | `5432` | Port PostgreSQL listens on |
| `postgres_listen_addresses` | `"*"` | Interfaces PostgreSQL binds to |
| `postgres_pg_hba_path` | `/etc/postgresql/{{ postgres_version }}/main/pg_hba.conf` | Path to `pg_hba.conf` |
| `postgres_allowed_cidrs` | `[]` | List of CIDRs allowed in `pg_hba.conf` (e.g. Kubernetes pod subnets) |
| `postgres_users` | `[]` | List of users/databases to create (see below) |

### Basic playbook usage

```yaml
- hosts: db_servers
  roles:
    - role: install-postgres
      vars:
        postgres_version: "16"
        postgres_listen_addresses: "*"
        postgres_allowed_cidrs:
          - "10.1.0.0/16"
```

---

## Managing PostgreSQL users and databases

Users and databases are defined in
`inventories/production/group_vars/all/postgres.yml`.
**Passwords are never stored there** — they live in an Ansible Vault-encrypted
file and are referenced by variable name.

### Variable structure

**`postgres.yml`** (plaintext, committed):

```yaml
# Databases and their users.
# Passwords come from postgres_vault.yml (ansible-vault encrypted).
postgres_users:
  - name: xdata-user-rw
    databases:
      - name: xdata
        priv: ALL          # ALL | SELECT | INSERT | UPDATE | DELETE | CONNECT
  - name: xdata-user-ro
    databases:
      - name: xdata
        priv: SELECT
```

> Each `name` under `postgres_users` **must** have a matching key in
> `vault_postgres_user_passwords` (see below). The role asserts this at
> runtime and fails with a clear message if the key is missing.

**`postgres_vault.yml`** (encrypted with `ansible-vault`, committed):

```yaml
vault_postgres_user_passwords:
  xdata-user-rw: "strongPasswordRw"
  xdata-user-ro: "strongPasswordRo"
```

---

## redis

### Role variables

| Variable | Default | Description |
|---|---|---|
| `redis_port` | `6379` | Port Redis listens on |
| `redis_bind` | `"0.0.0.0"` | Interfaces Redis binds to |
| `redis_require_password` | `true` | Set `requirepass` in `redis.conf` (requires `vault_redis_password`) |

### Basic playbook usage

```yaml
- hosts: cache_servers
  roles:
    - role: redis
```

### Password (vault)

When `redis_require_password: true` (the default), the role reads `vault_redis_password` from
`inventories/production/group_vars/all/redis_vault.yml`.

**`redis.yml`** (plaintext, committed):

```yaml
redis_port: 6379
redis_bind: "0.0.0.0"
redis_require_password: true
```

**`redis_vault.yml`** (encrypted with `ansible-vault`, committed):

```yaml
vault_redis_password: "your-strong-redis-password"
```

Encrypt the file before committing:

```bash
ansible-vault encrypt inventories/production/group_vars/all/redis_vault.yml
```

Edit it later:

```bash
ansible-vault edit inventories/production/group_vars/all/redis_vault.yml
```

---

## Ansible Vault — password management

### One-time setup

```bash
# 1. Create the vault password file (never committed — listed in .gitignore)
echo 'your-strong-vault-passphrase' > .vault_pass
chmod 600 .vault_pass

# 2. Populate vault files with real secrets, then encrypt them
ansible-vault encrypt inventories/production/group_vars/all/postgres_vault.yml
ansible-vault encrypt inventories/production/group_vars/all/redis_vault.yml
```

After encryption the file starts with:

```
$ANSIBLE_VAULT;1.1;AES256
3663386630...
```

### Day-to-day operations

```bash
# Edit secrets interactively (auto-decrypts, opens $EDITOR, re-encrypts on save)
ansible-vault edit inventories/production/group_vars/all/postgres_vault.yml

# View secrets without editing
ansible-vault view inventories/production/group_vars/all/postgres_vault.yml

# Add a new user — edit the vault file and add a key under vault_postgres_user_passwords:
#   new-user: "their_password"
# Then add the user to postgres.yml:
#   - name: new-user
#     databases:
#       - name: some_db
#         priv: ALL

# Run the playbook — vault is decrypted transparently via .vault_pass
ansible-playbook -i inventories/production playbooks/site.yml
```

### CI/CD (GitHub Actions)

Store the passphrase as a repository secret (`ANSIBLE_VAULT_PASS`) and write
it to `.vault_pass` at the start of the workflow:

```yaml
- name: Write vault password file
  run: |
    echo "${{ secrets.ANSIBLE_VAULT_PASS }}" > .vault_pass
    chmod 600 .vault_pass
```

### File summary

| File | Committed | Contains |
|---|---|---|
| `postgres_vault.yml` | Yes, **encrypted** | `vault_postgres_user_passwords` |
| `postgres.yml` | Yes, plaintext | `postgres_users` with `{{ vault_... }}` references |
| `redis_vault.yml` | Yes, **encrypted** | `vault_redis_password` |
| `redis.yml` | Yes, plaintext | `redis_port`, `redis_bind`, `redis_require_password` |
| `.vault_pass` | **No** (`.gitignore`) | The vault passphrase |
