<div align="center">

# HomeLab — chenar.space

**Kubernetes cluster running on two VPS nodes, fully GitOps-managed. Push to main, Flux deploys.**

[![k3s](https://img.shields.io/badge/k3s-v1.32.4-F8A002?style=flat-square&logo=kubernetes&logoColor=white)](https://k3s.io)
[![Flux CD](https://img.shields.io/badge/Flux_CD-v2.8.6-5468FF?style=flat-square&logo=flux&logoColor=white)](https://fluxcd.io)
[![Cilium](https://img.shields.io/badge/Cilium-1.15.6-F8C517?style=flat-square&logo=cilium&logoColor=black)](https://cilium.io)
[![Traefik](https://img.shields.io/badge/Traefik-v3-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)](https://traefik.io)
[![Rancher](https://img.shields.io/badge/Rancher-2.14-0075A8?style=flat-square&logo=rancher&logoColor=white)](https://rancher.com)

</div>

---

## Live Services

| URL | App | Access |
|-----|-----|--------|
| [chenar.space](https://chenar.space) | Portfolio | Public |
| [echovote.chenar.space](https://echovote.chenar.space) | EchoVote | Public |
| [echovote.dev.chenar.space](https://echovote.dev.chenar.space) | EchoVote Dev | IP restricted |
| [ai-jobs.chenar.space](https://ai-jobs.chenar.space) | AI Jobs UI (Streamlit) | Public |
| [ai-jobs-api.chenar.space](https://ai-jobs-api.chenar.space) | AI Jobs API (FastAPI) | Public |
| [rancher.chenar.space](https://rancher.chenar.space) | Rancher | IP restricted |
| [traefik.chenar.space](https://traefik.chenar.space) | Traefik Dashboard | IP restricted |
| [mongo.chenar.space](https://mongo.chenar.space) | MongoDB UI | IP restricted |
| [redis.chenar.space](https://redis.chenar.space) | RedisInsight | IP restricted |

---

## Stack

| | |
|--|--|
| Kubernetes | k3s v1.32.4 — 2 nodes (1 control-plane, 1 worker) |
| Networking | Cilium (eBPF, VXLAN, LB IPAM) |
| Ingress | Traefik — auto TLS via Let's Encrypt |
| GitOps | Flux CD — reconciles on every push via GitHub webhook |
| Cluster UI | Rancher |
| Secrets | Infisical Cloud — syncs to k8s Secrets, nothing in git |

---

## How deploys work

```
git push main
  └── GitHub webhook → Flux reconciles in seconds

git tag v1.2.3 && git push --tags
  └── CI builds :v1.2.3 → Flux updates image → rolling deploy
```

Dev builds (`:sha-*`, `:dev-timestamp`) go to `echovote-dev`. Semver tags go to prod.

---

## Repo layout

```
apps/
  production/echovote/     EchoVote prod
  production/portfolio/    Portfolio
  production/ai-jobs/      AI Jobs (ML salary/level predictor)
  dev/echovote/            Dev environment (IP restricted, scales to 0)
  private/                 Internal tools (mongo-express, redisinsight)
infrastructure/
  traefik/                 Ingress + TLS + IP allowlist middleware
  cert-manager/            Let's Encrypt issuer
  redis-operator/          Opstree Redis Operator
  rancher/                 Cluster UI
  cilium-lb/               LoadBalancer IP pool
clusters/vps-k3s/          Flux bootstrap + kustomizations
docs/                      Runbooks
```

---

## Redis

EchoVote uses Redis HA via [Opstree Redis Operator](https://github.com/OT-CONTAINER-KIT/redis-operator) — 3 data pods + 3 sentinel pods in the `echovote-infra` namespace.

Migrated from Bitnami Helm chart on 2026-05-17. Full story: [docs/redis-migration-bitnami-to-opstree.md](docs/redis-migration-bitnami-to-opstree.md)

---

## Secrets

Zero secrets in git. Infisical syncs everything into the cluster via Kubernetes auth.

| Infisical path | Used by |
|---|---|
| `/echovote` | App env + GHCR pull |
| `/echovote-mongo` | MongoDB credentials |
| `/echovote-redis` | Redis credentials |
| `/ai-jobs` | GHCR pull secret for AI Jobs namespace |
| `/flux` | Image pull + webhook token |
| `/rancher` | Bootstrap password |
| `/mongo-express` | UI auth + MongoDB URL |

---

## Operations

```bash
ssh homelab

kubectl get nodes
kubectl get pods -A
flux get all -A

# Force reconcile (webhook handles this automatically)
flux reconcile source git flux-system
flux reconcile kustomization apps-production --with-source

# Dev env
kubectl -n echovote-dev scale deploy --all --replicas=1   # wake up
kubectl -n echovote-dev scale deploy --all --replicas=0   # sleep
```

---

## Adding a new app

See [docs/adding-new-project.md](docs/adding-new-project.md) for the full template.

Short version: drop manifests in `apps/production/<name>/`, add the folder to the parent `kustomization.yaml`, push. DNS wildcard `*.chenar.space` already points at Traefik — no DNS config needed for new subdomains.

---

## DNS

| Type | Name | Value |
|------|------|-------|
| A | `@` | `178.105.91.23` |
| A | `*` | `178.105.91.23` |
| A | `*.dev` | `178.105.91.23` |
| CNAME | `www` | `chenar.space.` |
