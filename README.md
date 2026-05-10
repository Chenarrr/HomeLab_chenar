<div align="center">

# HomeLab — chenar.space

**Self-hosted Kubernetes on Hetzner Cloud, GitOps-managed, zero secrets in git.**

[![k3s](https://img.shields.io/badge/k3s-v1.32.4-F8A002?style=flat-square&logo=kubernetes&logoColor=white)](https://k3s.io)
[![Flux CD](https://img.shields.io/badge/Flux_CD-v2-5468FF?style=flat-square&logo=flux&logoColor=white)](https://fluxcd.io)
[![Cilium](https://img.shields.io/badge/Cilium-1.15.6-F8C517?style=flat-square&logo=cilium&logoColor=black)](https://cilium.io)
[![Traefik](https://img.shields.io/badge/Traefik-v3-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)](https://traefik.io)
[![Infisical](https://img.shields.io/badge/Secrets-Infisical-6B3FA0?style=flat-square)](https://infisical.com)

</div>

---

## Live

| URL | App | Namespace |
|-----|-----|-----------|
| [chenar.space](https://chenar.space) | Portfolio | `portfolio` |
| [echovote.chenar.space](https://echovote.chenar.space) | EchoVote | `echovote` |
| [echovote.dev.chenar.space](https://echovote.dev.chenar.space) | EchoVote Dev | `echovote-dev` |
| [traefik.chenar.space](https://traefik.chenar.space) | Traefik Dashboard | `traefik` |

---

## Stack

| Layer | Technology | Notes |
|-------|------------|-------|
| OS | Ubuntu 24.04 | Hetzner Cloud VPS |
| Kubernetes | k3s v1.32.4 | Lightweight, single binary |
| CNI | Cilium 1.15.6 | eBPF networking, VXLAN overlay, LB IPAM |
| Ingress | Traefik v3 | Automatic TLS, path-based routing |
| TLS | Traefik ACME | Let's Encrypt HTTP-01 |
| GitOps | Flux CD v2 | Image automation, Kustomize, auto-sync |
| Secrets | Infisical Cloud | Kubernetes auth, syncs to cluster |
| Provisioning | Ansible | Idempotent full-cluster setup |

---

## GitOps Flow

```
git push main
     │
     ├─► CI builds image
     │         ├─► ghcr.io/chenarrr/app:dev-20260511120000
     │         │        └─► Flux dev policy → echovote-dev namespace
     │         └─► ghcr.io/chenarrr/app:sha-abc123
     │
git tag v1.2.3 && git push --tags
     │
     └─► ghcr.io/chenarrr/app:v1.2.3
              └─► Flux prod policy → echovote namespace
                       └─► Rolling update, zero downtime
```

Flux commits the updated image tag back to this repo — no manual deploys.

---

## Repository Structure

```
HomeLab_chenar/
├── apps/
│   ├── production/
│   │   ├── echovote/          # Production app manifests
│   │   └── portfolio/         # Portfolio site
│   ├── dev/
│   │   └── echovote/          # Dev — auto-deploys on every push
│   └── private/
│       └── ...                # Internal tooling
├── infrastructure/
│   ├── cilium-lb/             # LoadBalancer IP pool
│   ├── cert-manager/
│   ├── cert-manager-issuers/
│   └── traefik/
└── clusters/
    └── vps-k3s/
        └── flux-system/       # Flux bootstrap + Kustomizations
```

---

## Secrets

Zero secrets in git. Everything lives in Infisical Cloud and syncs automatically via Kubernetes auth.

```
Infisical Cloud
      │  Kubernetes Auth (TokenReview API)
      ▼
InfisicalSecret CRD ──► k8s Secret ──► Pod env vars
```

| Infisical Path | Environment | Secret Name | Namespace |
|----------------|-------------|-------------|-----------|
| `/echovote` | prod | `echovote-secrets` | `echovote` |
| `/echovote` | dev | `echovote-secrets` | `echovote-dev` |
| `/echovote-mongo` | prod/dev | `mongo-helm-values` | both |
| `/echovote-redis` | prod/dev | `redis-helm-values` | both |
| `/flux` | prod | `echovote-ghcr-auth` | `flux-system` |

---

## Operations

```bash
# SSH
ssh -i ~/.ssh/id_ed25519_homelab root@178.105.91.23    # Control Plane
ssh -i ~/.ssh/id_ed25519_homelab root@178.104.119.245  # Worker

# Cluster health
kubectl get nodes
kubectl get pods -A
flux get all -A

# Force sync
flux reconcile source git flux-system
flux reconcile kustomization apps-production --with-source

# Infisical sync status
kubectl get infisicalsecrets -A
```

---

## Adding a New App

```bash
# 1. Create manifests
mkdir -p apps/production/myapp
# namespace.yaml, deployment.yaml, service.yaml, ingress.yaml, kustomization.yaml

# 2. Register
echo "  - myapp" >> apps/production/kustomization.yaml

# 3. Push — Flux reconciles automatically
git push origin main
```

> DNS wildcard `*.chenar.space` already points to Traefik — no DNS changes needed.

---

## DNS

| Type | Host | Value |
|------|------|-------|
| A | `@` | `178.105.91.23` |
| A | `*` | `178.105.91.23` |
| A | `*.dev` | `178.105.91.23` |
| CNAME | `www` | `chenar.space.` |
