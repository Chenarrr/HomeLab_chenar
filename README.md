<div align="center">

# HomeLab — chenar.space

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
| [api.liftlog.chenar.space](https://api.liftlog.chenar.space) | LiftLog API | Public |
| [echovote.dev.chenar.space](https://echovote.dev.chenar.space) | EchoVote Dev | IP restricted |
| [ai-jobs.chenar.space](https://ai-jobs.chenar.space) | AI Jobs UI | IP restricted |
| [ai-jobs-api.chenar.space](https://ai-jobs-api.chenar.space) | AI Jobs API | IP restricted |
| [rancher.chenar.space](https://rancher.chenar.space) | Rancher | IP restricted |
| [pgadmin.chenar.space](https://pgadmin.chenar.space) | pgAdmin 4 | IP restricted |
| `178.105.91.23:5432` | LiftLog Postgres | IP restricted (TCP) |

---

## Stack

| | |
|--|--|
| Kubernetes | k3s v1.32.4 — 2 nodes (1 control-plane, 1 worker) |
| Networking | Cilium (eBPF, VXLAN, LB IPAM) |
| Ingress | Traefik — auto TLS via Let's Encrypt, TCP entrypoint on :5432 |
| GitOps | Flux CD — reconciles on every push via GitHub webhook |
| Cluster UI | Rancher |
| Secrets | Infisical Cloud — syncs to k8s Secrets, nothing in git |

---

## How deploys work

```
git push main
  └── GitHub webhook → Flux reconciles in seconds

git tag v1.2.3 && git push --tags   (in app repo)
  └── CI builds :v1.2.3 → Flux image scan → rolling deploy
```

---

## Repo layout

```
apps/
  production/echovote/     EchoVote prod (Node + MongoDB + Redis HA)
  production/portfolio/    Portfolio (static)
  production/liftlog/      LiftLog API prod (Go + Postgres + Redis)
  production/ai-jobs/      AI Jobs (Streamlit + FastAPI)
  dev/echovote/            EchoVote dev (IP restricted, sha-tagged images)
  private/                 Internal tools (mongo-express, redisinsight)
infrastructure/
  traefik/                 Ingress + TLS + HTTP/TCP IP allowlist middleware
  cert-manager/            Let's Encrypt issuer
  redis-operator/          Opstree Redis Operator (EchoVote)
  rancher/                 Cluster UI
  cilium-lb/               LoadBalancer IP pool
clusters/vps-k3s/          Flux bootstrap + kustomizations
docs/                      Runbooks
```

---

## Redis

EchoVote uses Redis HA via [Opstree Redis Operator](https://github.com/OT-CONTAINER-KIT/redis-operator) — 3 data pods + 3 sentinel pods in `echovote-infra`.

LiftLog uses a single Redis deployment (active workout cache only, non-critical).

---

## Secrets

Zero secrets in git. Infisical syncs everything into the cluster via Kubernetes auth.

| Infisical path | Used by |
|---|---|
| `/echovote` | EchoVote app env + GHCR pull |
| `/echovote-mongo` | MongoDB credentials |
| `/echovote-redis` | Redis credentials |
| `/liftlog` | LiftLog app env + GHCR pull (DATABASE_URL, TOKEN_SECRET, REDIS_ADDR, REDIS_PASSWORD, .dockerconfigjson) |
| `/liftlog-postgres` | LiftLog Postgres credentials |
| `/ai-jobs` | GHCR pull secret for AI Jobs |
| `/flux` | Image pull + webhook token |
| `/rancher` | Bootstrap password |

---

## Operations

```bash
ssh homelab

kubectl get nodes
kubectl get pods -A
flux get all -A

# Force reconcile
flux reconcile source git flux-system
flux reconcile kustomization apps-production --with-source

# LiftLog DB access (home IP only)
psql -h 178.105.91.23 -p 5432 -U liftlog -d liftlog
```

---

## Adding a new app

Drop manifests in `apps/production/<name>/`, add to parent `kustomization.yaml`, push. DNS wildcard `*.chenar.space → 178.105.91.23` covers all subdomains automatically.

---

## DNS

| Type | Name | Value |
|------|------|-------|
| A | `@` | `178.105.91.23` |
| A | `*` | `178.105.91.23` |
| CNAME | `www` | `chenar.space.` |
