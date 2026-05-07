# HomeLab Chenar

**Domain:** `chenarrr.space` | **VPS:** Hetzner Cloud (`178.105.91.23`)  
GitOps-managed Kubernetes homelab. Talos Linux + Flux CD + Traefik.

---

## Domain & Applications

| URL | Purpose | Authentication |
|-----|---------|----------------|
| `https://chenarrr.space` | Traefik Dashboard (private) | BasicAuth |
| `https://infisical.chenarrr.space` | Infisical Secrets Manager (private) | Login |
| `https://echovote.chenarrr.space` | EchoVote application | Public |
| `https://<app>.chenarrr.space` | Future applications (auto-deploy) | Per-app |

**DNS Configuration (Namecheap):**
```
A     @              178.105.91.23
A     *              178.105.91.23
```

---

## Architecture

**Scalable for unlimited applications:**
1. Each application gets its own subdomain: `<app>.chenarrr.space`
2. Flux watches application repositories and auto-deploys to Kubernetes
3. Traefik routes traffic and handles SSL (Let's Encrypt)
4. Add new application = add GitRepository + Kustomization to `flux-system/`

---

## Cluster

| Node | IP | Role | Specs | OS |
|------|----|------|-------|----|
| `ubuntu-8gb-homelab1` | `178.105.91.23` | Control Plane | CX33, 8GB, 80GB | Talos 1.13 |
| `ubuntu-8gb-homelab2` | `178.104.119.245` | Worker | CX33, 8GB, 80GB | Talos 1.13 |

**Kubernetes:** v1.32.0 | **kubectl context:** `admin@homelab-cluster`

---

## Stack

| Layer | Technology |
|-------|------------|
| OS | Talos Linux 1.13 (no SSH, managed via `talosctl`) |
| Kubernetes | v1.32.0 |
| CNI | Cilium (eBPF) + LoadBalancer (L2) |
| Ingress | Traefik v3 (LoadBalancer on `178.105.91.23:80/443`) |
| SSL | cert-manager + Let's Encrypt (auto-renewal) |
| GitOps | Flux CD v2 (auto-sync every 1min) |
| Secrets | Infisical (dashboard + auto-sync) |
| Storage | local-path-provisioner v0.0.30 |

---

## Access

| Service | URL | Notes |
|---------|-----|-------|
| Traefik Dashboard | `https://chenarrr.space` | BasicAuth protected |
| Kubernetes API | `https://178.105.91.23:6443` | Restrict to your IP in Hetzner Firewall |
| Talos API | `178.105.91.23:50000` | Restrict to your IP in Hetzner Firewall |

---

## Deployed Applications

| Application | Subdomain | Namespace | Repository |
|-------------|-----------|-----------|------------|
| EchoVote | `echovote.chenarrr.space` | `echovote` | [gitops-echovote](https://github.com/Chenarrr/gitops-echovote) |

---

## Adding New Applications (Scalable Pattern)

**For each new application:**

1. **Create application GitOps repository** (e.g., `gitops-myapp`)
   ```yaml
   gitops-myapp/
   ├── deployment.yaml
   ├── service.yaml
   ├── ingressroute.yaml  # Points to myapp.chenarrr.space
   └── kustomization.yaml
   ```

2. **Add to HomeLab_chenar:**
   ```bash
   # In flux-system/flux-system/
   # Create myapp-source.yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata:
     name: myapp
     namespace: flux-system
   spec:
     interval: 1m
     url: https://github.com/Chenarrr/gitops-myapp
     ref:
       branch: main
   
   # Create myapp-kustomization.yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: myapp
     namespace: flux-system
   spec:
     interval: 1m
     sourceRef:
       kind: GitRepository
       name: myapp
     path: ./
     prune: true
   ```

3. **Reference in `flux-system/flux-system/kustomization.yaml`**
4. **Commit and push** - Flux auto-deploys to `myapp.chenarrr.space`

**Scales to 50+ applications** - repeat this pattern for each application.

---

## Management Commands

```bash
# Cluster health
kubectl get nodes
flux get all -A

# Force sync all applications
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# Check Traefik routes
kubectl get ingressroutes -A

# View SSL certificates
kubectl get certificates -A

# Logs
kubectl logs -n traefik -l app.kubernetes.io/name=traefik
kubectl logs -n cert-manager -l app=cert-manager
```

---

## Security

- **No SSH** - Talos managed via `talosctl` (port 50000, mTLS)
- **Firewall** - Restrict ports 50000 & 6443 to your IP only
- **SSL** - Auto-renewed Let's Encrypt certificates
- **Dashboard** - BasicAuth protected
- **Secrets** - Managed with Infisical (see [SECRETS.md](./SECRETS.md))

**All secrets in one dashboard. Auto-sync to cluster. No manual kubectl commands.**

---

## DNS Configuration (Namecheap)

Go to `chenarrr.space` → Advanced DNS:

| Type | Host | Value | TTL |
|------|------|-------|-----|
| A | @ | 178.105.91.23 | Automatic |
| A | * | 178.105.91.23 | Automatic |

**Propagation:** 5-30 minutes. Check with `dig chenarrr.space`
