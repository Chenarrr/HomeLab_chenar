# HomeLab Chenar

GitOps-managed Kubernetes homelab on Hetzner Cloud. Talos Linux + Flux CD.

---

## Cluster

| Node | IP | Role | Specs | OS |
|------|----|------|-------|----|
| `ubuntu-8gb-homelab1` | `178.105.91.23` | Control Plane (API `:6443`) | CX33, 8GB, 80GB | Talos 1.13 |
| `ubuntu-8gb-homelab2` | `178.104.119.245` | Worker | CX33, 8GB, 80GB | Talos 1.13 |

**Kubernetes:** v1.32.0 · **kubectl context:** `admin@homelab-cluster`

---

## Stack

| Layer | Tech |
|-------|------|
| OS | Talos Linux 1.13 (no SSH — managed via `talosctl` on port 50000) |
| K8s | v1.32.0 |
| CNI | Cilium (eBPF) |
| Ingress | Traefik v3 — NodePort 30080 (HTTP), 30443 (HTTPS), 30900 (dashboard) |
| GitOps | Flux CD v2 |
| Storage | local-path-provisioner v0.0.30 (default SC) |
| Image sync | image-reflector-controller v0.34.0 + image-automation-controller v0.39.0 |

---

## Access

| What | URL |
|------|-----|
| EchoVote app | `http://178.105.91.23:30080` |
| Traefik dashboard | `http://178.105.91.23:30900/dashboard/` |
| K8s API | `https://178.105.91.23:6443` (restrict to your IP in Hetzner Firewall) |
| Talos API | `178.105.91.23:50000` (restrict to your IP in Hetzner Firewall) |

---

## GitOps repos

| Repo | Purpose |
|------|---------|
| [HomeLab_chenar](https://github.com/Chenarrr/HomeLab_chenar) | Cluster bootstrap — Flux components + app source refs |
| [gitops-echovote](https://github.com/Chenarrr/gitops-echovote) | EchoVote app manifests — server, client, MongoDB, Redis |

Flux watches both repos. `HomeLab_chenar` bootstraps the cluster and points Flux at `gitops-echovote`. App changes go in `gitops-echovote` only.

---

## Repo structure

```
HomeLab_chenar/
├── flux-system/
│   └── flux-system/
│       ├── gotk-components.yaml        # Flux controllers + CRDs (auto-managed)
│       ├── gotk-sync.yaml              # Watches this repo
│       ├── kustomization.yaml          # Entry point — includes all files below
│       ├── traefik-kustomization.yaml  # Kustomization → infrastructure/traefik
│       ├── echovote-source.yaml        # GitRepository → gitops-echovote
│       └── echovote-kustomization.yaml # Kustomization → k8s/ in gitops-echovote
└── infrastructure/
    └── traefik/
        ├── namespace.yaml              # traefik namespace
        ├── helmrepository.yaml         # Traefik Helm chart source (traefik.github.io)
        ├── helmrelease.yaml            # Traefik v3 install — NodePort 30080/30443/30900
        └── kustomization.yaml          # Kustomize wrapper for this directory
```

---

## Deployed apps

| App | Namespace | URL |
|-----|-----------|-----|
| EchoVote (server + client + MongoDB + Redis) | `echovote` | `http://178.105.91.23:30080` |

---

## Adding a new app

1. Create a GitOps repo for the app (manifests, image-automation)
2. Add `<app>-source.yaml` + `<app>-kustomization.yaml` to `flux-system/flux-system/`
3. Reference both in `flux-system/flux-system/kustomization.yaml`
4. Commit + push — Flux picks up changes within 1 minute

See `gitops-echovote` as a reference implementation.

---

## Connect

```bash
export KUBECONFIG=~/.kube/config
export TALOSCONFIG=~/talos-config/talosconfig

# Cluster health
kubectl get nodes
talosctl --talosconfig ~/talos-config/talosconfig --nodes 178.105.91.23 health

# Flux status
flux get all -A
kubectl get gitrepositories,kustomizations,imagepolicies -n flux-system

# Force sync
kubectl annotate gitrepository flux-system \
  -n flux-system reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite

# Force Traefik reconcile
flux reconcile helmrelease traefik -n traefik
```

---

## Security notes

- Talos has no SSH. All node management via `talosctl` (gRPC, port 50000, mTLS).
- **Hetzner Firewall**: restrict port 50000 (Talos) and 6443 (K8s API) to your IP only.
- Secrets never in Git — created via bootstrap workflows or direct `kubectl create secret`.
- All app pods: non-root, read-only root filesystem, `drop: ["ALL"]` capabilities, seccomp RuntimeDefault.
