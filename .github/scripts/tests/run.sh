#!/usr/bin/env bash
# Self test of cleanup-oneshot.py: the cleaned fixtures must equal the expected files, a second
# run must not change anything, and the result must pass yamllint.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R "$here/before/." "$tmp/"
python3 "$here/../cleanup-oneshot.py" --root "$tmp" --tags "" --log "$here/deploy.log" --report "$tmp/report.md" > /dev/null
diff -ru "$here/expected" "$tmp" --exclude=report.md
snapshot="$(cat "$tmp"/inventories/production/group_vars/all/*.yml)"
python3 "$here/../cleanup-oneshot.py" --root "$tmp" --tags "" --log "$here/deploy.log" --report "$tmp/report2.md" > /dev/null
[ "$snapshot" = "$(cat "$tmp"/inventories/production/group_vars/all/*.yml)" ] || { echo "second run changed the files"; exit 1; }
# Only some tags deployed: the other files stay as they are.
rm -rf "$tmp"/inventories && cp -R "$here/before/inventories" "$tmp/"
python3 "$here/../cleanup-oneshot.py" --root "$tmp" --tags "secrets" --report "$tmp/report3.md" > /dev/null
diff -u "$here/before/inventories/production/group_vars/all/postgres.yml" "$tmp/inventories/production/group_vars/all/postgres.yml"
diff -u "$here/before/inventories/production/group_vars/all/argocd.yml" "$tmp/inventories/production/group_vars/all/argocd.yml"
yamllint -d relaxed "$here/expected"
echo "cleanup-oneshot self test: ok"
