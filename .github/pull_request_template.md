## What and why

<!-- What changes, and why. Link the issue or discussion if there is one. -->

## How to test

<!-- Commands you ran or steps to verify. Paste the relevant output when it helps. -->

## Checklist

- [ ] PR title follows `type(scope): subject`, for example `feat(courier): add retry`
- [ ] `make lint` and `make syntax` pass
- [ ] `make check` (dry run) reviewed for the tags that change
- [ ] Vault files are encrypted (`head -1` shows `$ANSIBLE_VAULT`)
- [ ] Destructive options (`postgres_allow_drop_databases`, `postgres_prune_unmanaged: delete`) are intentional
- [ ] No secrets, tokens or private keys in the diff
- [ ] Docs (`README.md`) updated when behaviour or setup changed
