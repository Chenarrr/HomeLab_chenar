# HomeLab Chenar

GitOps-managed Kubernetes homelab on Hetzner Cloud. Powered by Talos + Flux.

## Cluster

| Node | IP | Role | Specs |
|------|----|------|-------|
| `ubuntu-8gb-homelab1` | `178.105.91.23` | Control Plane | CX33, 8GB, 80GB |
| `ubuntu-8gb-homelab2` | `178.104.119.245` | Worker | CX33, 8GB, 80GB |

## Stack

| Layer | Tech |
|-------|------|
| OS | Talos Linux 1.12.4 |
| K8s | v1.32.0 |
| CNI | Cilium 1.19.3 |
| GitOps | Flux CD |

## Repo Structure

```
HomeLab_chenar/
├── flux-system/        # Flux controllers (auto-managed, don't edit)
├── clusters/
│   └── homelab/        # Kustomizations pointing to apps + infra
├── apps/
│   ├── base/           # App manifests (deployments, services, ingress)
│   └── homelab/        # Homelab-specific overlays / patches
└── infrastructure/
    ├── base/           # Shared infra (cert-manager, ingress, monitoring)
    └── homelab/        # Homelab-specific infra config
```

## How it works

1. Push manifests to this repo
2. Flux detects changes (every 1 min)
3. Cluster reconciles automatically

## Connect

```bash
export KUBECONFIG=~/talos-config/kubeconfig
export TALOSCONFIG=~/talos-config/talosconfig

kubectl get nodes
flux get all -A
```
