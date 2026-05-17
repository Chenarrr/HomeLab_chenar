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

## Live

| URL | App | Access |
|-----|-----|--------|
| [chenar.space](https://chenar.space) | Portfolio | Public |
| [echovote.chenar.space](https://echovote.chenar.space) | EchoVote | Public |
| [echovote.dev.chenar.space](https://echovote.dev.chenar.space) | EchoVote Dev | Private — IP restricted |
| [rancher.chenar.space](https://rancher.chenar.space) | Rancher | Private — IP restricted |
| [traefik.chenar.space](https://traefik.chenar.space) | Traefik Dashboard | Private — IP restricted |
| [mongo.chenar.space](https://mongo.chenar.space) | MongoDB UI (mongo-express) | Private — IP restricted |
| [redis.chenar.space](https://redis.chenar.space) | Redis UI (RedisInsight) | Private — IP restricted |

---

## Stack

| Layer | Technology | Notes |
|-------|------------|-------|
| OS | Ubuntu 24.04 | Hetzner Cloud VPS |
| Kubernetes | k3s v1.32.4 | Lightweight, single binary |
| CNI | Cilium 1.15.6 | eBPF networking, VXLAN overlay, LB IPAM |
| Ingress | Traefik v3.7 | Automatic TLS, ACME HTTP-01, persistent cert storage |
| TLS | Let's Encrypt | Per-domain certs, stored in PVC (survives restarts) |
| GitOps | Flux CD v2 | Instant reconcile on push via GitHub webhook |
| Cluster UI | Rancher 2.14 | Runs on control-plane, private access only |
| Secrets | Infisical Cloud | Kubernetes auth, syncs to cluster — nothing in git |
| Provisioning | Ansible | Idempotent full-cluster setup |

---

## GitOps Flow

```
git push main
     │
     ├─► GitHub webhook → webhook.chenar.space → Flux reconciles instantly
     │
     ├─► CI builds image
     │         ├─► ghcr.io/chenarrr/app:dev-20260511120000
     │         │        └─► Flux dev policy → echovote-dev (scaled to 0 by default)
     │         └─► ghcr.io/chenarrr/app:sha-abc123
     │
git tag v1.2.3 && git push --tags
     │
     └─► ghcr.io/chenarrr/app:v1.2.3
              └─► Flux prod policy → echovote namespace
                       └─► Rolling update, zero downtime
```

Every `git push` triggers instant Flux reconcile via GitHub webhook — no polling, no manual deploys.

---

## Repository Structure

```
HomeLab_chenar/
├── apps/
│   ├── production/
│   │   ├── echovote/          # Production app + Opstree Redis (echovote-infra ns)
│   │   └── portfolio/         # Portfolio site (public)
│   ├── dev/
│   │   └── echovote/          # Dev — IP-restricted, scaled to 0 when idle
│   └── private/
│       ├── mongo-express/     # MongoDB UI — IP-restricted
│       └── redisinsight/      # Redis UI — IP-restricted
├── infrastructure/
│   ├── cilium-lb/             # LoadBalancer IP pool
│   ├── cert-manager/          # TLS cert issuer
│   ├── cert-manager-issuers/
│   ├── traefik/               # Ingress, ACME, IP allowlist middleware
│   └── rancher/               # Cluster management UI (private)
└── clusters/
    └── vps-k3s/
        └── flux-system/       # Flux bootstrap + Kustomizations
```

---

## Access Control

Private services use Traefik `IPAllowList` middleware — all traffic from unlisted IPs gets 403 before reaching the app. Defined once in `infrastructure/traefik/private-access-middleware.yaml`, referenced by any IngressRoute that needs it.

---

## Security

Defense in depth across every app namespace:

| Layer | What |
|-------|------|
| **Pod Security Standards** | `restricted` enforced on all app namespaces — k8s rejects any non-hardened pod at admission |
| **SecurityContext** | All pods: `runAsNonRoot`, drop ALL caps, `seccomp: RuntimeDefault`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem` where possible |
| **NetworkPolicies** | `default-deny-ingress` per namespace + explicit allows (traefik → app, app → DB only) |
| **ServiceAccounts** | Dedicated SA per workload with `automountServiceAccountToken: false` — no k8s API tokens in pods |
| **Secrets** | Zero in git — synced from Infisical Cloud via Kubernetes auth |
| **TLS** | Let's Encrypt per-domain, auto-renewed by cert-manager |

---

## Secrets

Zero secrets in git. Everything lives in Infisical Cloud and syncs automatically via Kubernetes auth.

```
Infisical Cloud
      │  Kubernetes Auth (TokenReview API)
      ▼
InfisicalSecret CRD ──► k8s Secret ──► Pod env vars / Helm values
```

| Infisical Path | Used by |
|----------------|---------|
| `/echovote` | App secrets + GHCR pull |
| `/echovote-mongo` | MongoDB credentials |
| `/echovote-redis` | Redis credentials (Opstree Redis Operator) |
| `/flux` | Flux image pull secret + GitHub webhook token |
| `/rancher` | Rancher bootstrap password |
| `/mongo-express` | mongo-express auth + MongoDB URL |

---

## EchoVote Redis Stack

Redis HA via [Opstree Redis Operator](https://github.com/OT-CONTAINER-KIT/redis-operator) in `echovote-infra` namespace.

| Component | Kind | Pods | Notes |
|-----------|------|------|-------|
| RedisReplication | CRD | 3 (1 master + 2 replicas) | `quay.io/opstree/redis:v7.0.15`, 2Gi PVC each |
| RedisSentinel | CRD | 3 | Watches replication, auto-failover, quorum 2 |

**Server connects via sentinel:**
```
REDIS_SENTINEL_HOSTS=echovote-redis-v2-sentinel.echovote-infra.svc.cluster.local:26379
REDIS_SENTINEL_MASTER=mymaster
```

**Migrated from Bitnami Redis Sentinel → Opstree (2026-05-17)** using [RedisShake](https://github.com/tair-opensource/RedisShake) v4 for zero-downtime, zero data-loss live sync:

1. Deploy Opstree operator (`infrastructure/redis-operator/`)
2. Create `RedisReplication` + `RedisSentinel` CRDs in `echovote-infra`
3. Deploy RedisShake as PSYNC bridge (Bitnami master → Opstree master)
4. Verify identical key counts in both instances (RedisInsight)
5. Update server `REDIS_SENTINEL_HOSTS` → Opstree sentinel
6. Delete RedisShake, remove Bitnami HelmRelease

> **Why separate namespace?** Kubernetes auto-injects service env vars — `REDIS_PORT=tcp://...` from the Bitnami service collides with Opstree sentinel startup. `echovote-infra` has no Bitnami service → no collision.

---

## Operations

```bash
# SSH
ssh homelab    # Control plane (178.105.91.23)

# Cluster health
kubectl get nodes
kubectl get pods -A
flux get all -A

# Scale dev up/down
kubectl -n echovote-dev scale deploy --all --replicas=1   # start dev
kubectl -n echovote-dev scale deploy --all --replicas=0   # stop dev

# Force sync (normally not needed — webhook handles it)
flux reconcile source git flux-system
flux reconcile kustomization apps-production --with-source
```

---

## Adding a New App

```bash
# 1. Create manifests
mkdir -p apps/production/myapp
# namespace.yaml, deployment.yaml, service.yaml, ingress.yaml, kustomization.yaml

# 2. Register
echo "  - myapp" >> apps/production/kustomization.yaml

# 3. Push — Flux reconciles automatically within 1m
git push origin main
```

> DNS wildcard `*.chenar.space` already points to Traefik — no DNS changes needed for new subdomains.

---

## DNS

| Type | Host | Value |
|------|------|-------|
| A | `@` | `178.105.91.23` |
| A | `*` | `178.105.91.23` |
| A | `*.dev` | `178.105.91.23` |
| CNAME | `www` | `chenar.space.` |
