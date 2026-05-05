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
| OS | Talos Linux 1.13 |
| K8s | v1.32.0 |
| CNI | Cilium (eBPF) |
| Ingress | nginx-ingress (NodePort 30080/30443) |
| GitOps | Flux CD v2 |
| Storage | local-path-provisioner v0.0.30 (default SC) |
| Image sync | image-reflector v0.34.0 + image-automation v0.39.0 |

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
└── flux-system/
    └── flux-system/
        ├── gotk-components.yaml       # Flux controllers (auto-managed)
        ├── gotk-sync.yaml             # Watches this repo
        ├── kustomization.yaml         # Includes echovote source + kustomization
        ├── echovote-source.yaml       # GitRepository → gitops-echovote
        └── echovote-kustomization.yaml # Kustomization → k8s/ in gitops-echovote
```

---

## Deployed apps

| App | Namespace | Status |
|-----|-----------|--------|
| EchoVote (server + client + MongoDB + Redis) | `echovote` | ✅ Running |

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
```
