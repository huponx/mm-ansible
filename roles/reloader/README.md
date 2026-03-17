# Role: reloader

Installs [Stakater Reloader](https://github.com/stakater/Reloader) via Helm on a MicroK8s cluster.

Reloader watches ConfigMaps and Secrets and triggers rolling updates on Deployments, StatefulSets, and DaemonSets that reference them via annotations.

## Requirements

- MicroK8s with the `helm3` addon enabled (provided by the `microk8s` role).

## Variables

| Variable | Default | Description |
|---|---|---|
| `reloader_namespace` | `reloader` | Kubernetes namespace to install Reloader into |
| `reloader_chart_version` | `""` | Helm chart version; empty means latest |
| `reloader_helm_release` | `reloader` | Helm release name |
| `reloader_helm_repo_name` | `stakater` | Helm repository alias |
| `reloader_helm_repo_url` | `https://stakater.github.io/stakater-charts` | Helm repository URL |

## Usage

Add the role to `playbooks/site.yml`:

```yaml
- hosts: all
  become: yes
  roles:
    - microk8s
    - reloader
```

### Annotating workloads

After installation, annotate workloads to opt in to automatic restarts:

```yaml
# Restart when any referenced ConfigMap or Secret changes
annotations:
  reloader.stakater.com/auto: "true"

# Restart only when a specific ConfigMap changes
annotations:
  configmap.reloader.stakater.com/reload: "my-configmap"

# Restart only when a specific Secret changes
annotations:
  secret.reloader.stakater.com/reload: "my-secret"
```
