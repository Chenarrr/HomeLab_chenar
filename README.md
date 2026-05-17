<div align="center">

# HomeLab — chenar.space

**Self-hosted Kubernetes on Hetzner Cloud, GitOps-managed, zero secrets in git.**

[![k3s](https://img.shields.io/badge/k3s-v1.32.4-F8A002?style=flat-square&logo=kubernetes&logoColor=white)](https://k3s.io)
[![Flux CD](https://img.shields.io/badge/Flux_CD-v2-5468FF?style=flat-square&logo=flux&logoColor=white)](https://fluxcd.io)
[![Cilium](https://img.shields.io/badge/Cilium-1.15.6-F8C517?style=flat-square&logo=cilium&logoColor=black)](https://cilium.io)
[![Traefik](https://img.shields.io/badge/Traefik-v3.7-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)](https://traefik.io)
[![Rancher](https://img.shields.io/badge/Rancher-2.14-0075A8?style=flat-square&logo=rancher&logoColor=white)](https://rancher.com)
[![Infisical](https://img.shields.io/badge/Secrets-Infisical-6B3FA0?style=flat-square)](https://infisical.com)

</div>

---

## Live Services

| URL | App | Access |
|-----|-----|--------|
| [chenar.space](https://chenar.space) | Portfolio | Public |
| [echovote.chenar.space](https://echovote.chenar.space) | EchoVote | Public |
| [echovote.dev.chenar.space](https://echovote.dev.chenar.space) | EchoVote Dev | IP restricted |
| [rancher.chenar.space](https://rancher.chenar.space) | Rancher | IP restricted |
| [traefik.chenar.space](https://traefik.chenar.space) | Traefik Dashboard | IP restricted |
| [mongo.chenar.space](https://mongo.chenar.space) | MongoDB UI | IP restricted |
| [redis.chenar.space](https://redis.chenar.space) | RedisInsight | IP restricted |

---

## Stack

| Layer | Technology | Notes |
|-------|------------|-------|
| OS | Ubuntu 24.04 | Hetzner Cloud VPS |
| Kubernetes | k3s v1.32.4 | 2 nodes — 1 control-plane, 1 worker |
| CNI | Cilium 1.15.6 | eBPF networking, VXLAN overlay, LB IPAM |
| Ingress | Traefik v3.7 | Automatic TLS via ACME HTTP-01 |
| GitOps | Flux CD v2 | Instant reconcile on push via GitHub webhook |
| Cluster UI | Rancher 2.14 | Private access only |
| Secrets | Infisical Cloud | Syncs to cluster via Kubernetes auth — nothing in git |
| Provisioning | Ansible | Idempotent full-cluster setup |

---

## GitOps Flow

```
git push main
     │
     ├── GitHub webhook → Flux reconciles instantly
     │
     └── CI builds image
              ├── :dev-timestamp  → echovote-dev   (scaled to 0 when idle)
              └── :sha-abc123

git tag v1.2.3 && git push --tags
     │
     └── :v1.2.3 → echovote (prod) → rolling update, zero downtime
```

---

## Repository Structure

```
HomeLab_chenar/
├── apps/
│   ├── production/
│   │   ├── echovote/       # EchoVote prod — server, client, MongoDB, Redis
│   │   └── portfolio/      # Portfolio site
│   ├── dev/
│   │   └── echovote/       # EchoVote dev — IP restricted, scaled to 0 when idle
│   └── private/
│       ├── mongo-express/  # MongoDB UI
│       └── redisinsight/   # Redis UI
├── infrastructure/
│   ├── cilium-lb/          # LoadBalancer IP pool
│   ├── cert-manager/       # TLS cert issuer
│   ├── traefik/            # Ingress, ACME, IP allowlist middleware
│   ├── redis-operator/     # Opstree Redis Operator (CRD manager)
│   └── rancher/            # Cluster management UI
├── docs/                   # Runbooks and architecture notes
└── clusters/
    └── vps-k3s/
        └── flux-system/    # Flux bootstrap + Kustomizations
```

---

## Security

| Layer | Details |
|-------|---------|
| **Pod Security Standards** | `restricted` on all app namespaces — non-hardened pods rejected at admission |
| **SecurityContext** | `runAsNonRoot`, drop ALL caps, `seccomp: RuntimeDefault`, `allowPrivilegeEscalation: false` |
| **NetworkPolicies** | `default-deny-ingress` per namespace + explicit allows per traffic path |
| **ServiceAccounts** | Dedicated SA per workload, `automountServiceAccountToken: false` |
| **Secrets** | Zero in git — synced from Infisical Cloud via Kubernetes auth |
| **TLS** | Let's Encrypt per-domain, auto-renewed by cert-manager |

Private services use Traefik `IPAllowList` middleware — unlisted IPs get 403 before reaching the app.

---

## Secrets

Zero secrets in git. Infisical Cloud syncs everything to the cluster automatically.

```
Infisical Cloud
      │  Kubernetes Auth (TokenReview API)
      ▼
InfisicalSecret CRD → k8s Secret → Pod env vars
```

| Path | Used by |
|------|---------|
| `/echovote` | App secrets + GHCR pull |
| `/echovote-mongo` | MongoDB credentials |
| `/echovote-redis` | Redis credentials |
| `/flux` | Flux image pull + GitHub webhook token |
| `/rancher` | Rancher bootstrap password |
| `/mongo-express` | mongo-express auth + MongoDB URL |

---

## EchoVote — Redis

Redis HA via [Opstree Redis Operator](https://github.com/OT-CONTAINER-KIT/redis-operator) in `echovote-infra` namespace — 3 data pods (1 master + 2 replicas) + 3 sentinel pods.

The server connects via sentinel so writes always route to the current master:
```
REDIS_SENTINEL_HOSTS = echovote-redis-v2-sentinel.echovote-infra.svc.cluster.local:26379
REDIS_SENTINEL_MASTER = mymaster
```

Migrated from Bitnami Redis Sentinel on 2026-05-17 using [RedisShake](https://github.com/tair-opensource/RedisShake) — zero downtime, zero data loss.
→ Full runbook: [`docs/redis-migration-bitnami-to-opstree.md`](docs/redis-migration-bitnami-to-opstree.md)

---

## Operations

```bash
# SSH into control plane
ssh homelab

# Cluster health
kubectl get nodes
kubectl get pods -A
flux get all -A

# Force Flux reconcile (webhook normally handles this)
flux reconcile source git flux-system
flux reconcile kustomization apps-production --with-source

# Scale dev env
kubectl -n echovote-dev scale deploy --all --replicas=1   # up
kubectl -n echovote-dev scale deploy --all --replicas=0   # down
```

---

## Adding a New App

```bash
# 1. Create manifests
mkdir -p apps/production/myapp
# Add: namespace.yaml, deployment.yaml, service.yaml, ingress.yaml, kustomization.yaml

# 2. Register with Flux
echo "  - myapp" >> apps/production/kustomization.yaml

# 3. Push — Flux reconciles automatically
git push origin main
```

DNS wildcard `*.chenar.space` already points to Traefik — no DNS changes needed.

---

## DNS

| Type | Host | Value |
|------|------|-------|
| A | `@` | `178.105.91.23` |
| A | `*` | `178.105.91.23` |
| A | `*.dev` | `178.105.91.23` |
| CNAME | `www` | `chenar.space.` |
