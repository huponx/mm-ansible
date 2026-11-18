#!/usr/bin/env bash
# Reads the changed file names (one per line, from `git diff --name-only`) on stdin and decides
# what a push to main must deploy. Writes `mode` and `tags` to $GITHUB_OUTPUT (or stdout).
#
#   mode=none  only files that do not change the server (docs, CI, tooling): do not deploy
#   mode=tags  only files of some components: deploy just their tags
#   mode=all   anything else (playbooks, inventory, ansible.cfg, requirements.yml, unknown paths)
set -euo pipefail

tags=""
mode=none

add_tag() { tags="$tags$1"$'\n'; [ "$mode" = all ] || mode=tags; }

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    # Do not change the server
    *.md | .github/* | Makefile | .ansible-lint | .yamllint | .gitignore | .env.example | requirements.txt)
      ;;
    roles/microk8s/*) add_tag microk8s ;;
    roles/coredns/*) add_tag coredns ;;
    roles/argocd/*) add_tag argocd ;;
    roles/reloader/*) add_tag reloader ;;
    roles/application-pvc/*) add_tag pvc ;;
    roles/k8s-secrets/*) add_tag secrets ;;
    roles/vault/*) add_tag vault ;;
    roles/postgres/*) add_tag postgres ;;
    roles/redis/*) add_tag redis ;;
    roles/common/*) add_tag common ;;
    roles/backup/*) add_tag backup ;;
    inventories/production/group_vars/all/argocd*.yml) add_tag argocd ;;
    inventories/production/group_vars/all/coredns*.yml) add_tag coredns ;;
    inventories/production/group_vars/all/k8s_secrets*.yml) add_tag secrets ;;
    inventories/production/group_vars/all/microk8s*.yml) add_tag microk8s ;;
    inventories/production/group_vars/all/postgres*.yml) add_tag postgres ;;
    inventories/production/group_vars/all/redis*.yml) add_tag redis ;;
    inventories/production/group_vars/all/vault.yml) add_tag vault ;;
    # playbooks/, hosts.ini, other group_vars, ansible.cfg, requirements.yml, new roles...
    *) mode=all ;;
  esac
done

out="${GITHUB_OUTPUT:-/dev/stdout}"
joined=""
if [ "$mode" = tags ]; then
  joined=$(printf '%s' "$tags" | sort -u | paste -sd, -)
fi
{
  echo "mode=$mode"
  echo "tags=$joined"
} >> "$out"
