# Adding a New Project

## Tier choice

| Tier | Folder | Access |
|------|--------|--------|
| Production | `apps/production/<appname>/` | Public — world can reach it |
| Private | `apps/private/<appname>/` | Your home IP only (185.240.17.117) |

Both tiers are synced by Flux automatically once you push.

---

## Step 1 — Create folder structure

```
apps/production/myapp/          (or apps/private/myapp/)
├── kustomization.yaml
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── ingress.yaml
├── secrets/
│   └── myapp-secrets.yaml      (InfisicalSecret — no real secrets in git)
└── image-automation/           (optional — only if using Flux image auto-update)
    ├── imagerepositories.yaml
    ├── imagepolicies.yaml
    └── imageupdateautomation.yaml
```

---

## Step 2 — namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
```

---

## Step 3 — ingress.yaml

**Production (public):**
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myapp
  namespace: myapp
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myapp.chenar.space`)
      kind: Rule
      services:
        - name: myapp
          port: 3000
  tls:
    certResolver: letsencrypt-prod
```

**Private (your IP only) — add the middleware block:**
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myapp
  namespace: myapp
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myapp.chenar.space`)
      kind: Rule
      middlewares:
        - name: private-access      # defined in infrastructure/traefik/
          namespace: traefik
      services:
        - name: myapp
          port: 3000
  tls:
    certResolver: letsencrypt-prod
```

---

## Step 4 — secrets/myapp-secrets.yaml

Never put real secrets in git. Use InfisicalSecret — it syncs from Infisical Cloud.

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: myapp-secrets-sync
  namespace: myapp
spec:
  hostAPI: https://app.infisical.com/api
  syncConfig:
    resyncInterval: 60s
  authentication:
    kubernetesAuth:
      identityId: "YOUR_MACHINE_IDENTITY_ID"
      autoCreateServiceAccountToken: true
      serviceAccountRef:
        name: infisical-service-account
        namespace: default
      secretsScope:
        projectSlug: "YOUR_PROJECT_SLUG"
        envSlug: "prod"
        secretsPath: "/myapp"       # create this path in Infisical Cloud
        recursive: false
  managedKubeSecretReferences:
    - secretName: myapp-secrets     # k8s Secret name your pods reference
      secretNamespace: myapp
      secretType: Opaque
      creationPolicy: Owner
      template:
        includeAllSecrets: true
```

Put the actual secrets in **Infisical Cloud** under path `/myapp` in your project.

---

## Step 5 — kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - secrets/myapp-secrets.yaml
  # add image-automation/ files here if using Flux image updates
```

---

## Step 6 — Register app with Flux

Add one line to the parent kustomization:

**Production app** → `apps/production/kustomization.yaml`:
```yaml
resources:
  - echovote
  - myapp      # ← add this
```

**Private app** → `apps/private/kustomization.yaml`:
```yaml
resources:
  - myapp      # ← add this
```

---

## Step 7 — DNS

Add an A record pointing `myapp.chenar.space` to your Traefik LoadBalancer IP.

Get the IP after cluster is up:
```bash
kubectl get svc -n traefik
# EXTERNAL-IP column = your IP
```

---

## Step 8 — Push

```bash
git add .
git commit -m "feat(apps): add myapp"
# then push when ready
```

Flux detects the new commit within 1 minute and deploys.

---

## Optional — Image Automation (Flux auto-updates image tags)

Only needed if you want Flux to auto-commit new image tags when you push to GHCR.

### image-automation/imagerepositories.yaml
```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: myapp
  namespace: flux-system
spec:
  image: ghcr.io/chenarrr/myapp
  interval: 5m
  secretRef:
    name: echovote-ghcr-auth    # reuse existing GHCR auth secret
```

### image-automation/imagepolicies.yaml
```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: myapp
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: myapp
  # semver tags only (v1.2.3) — SHA tags are ignored (dev quality)
  filterTags:
    pattern: '^v(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$'
    extract: '$major.$minor.$patch'
  policy:
    semver:
      range: '>=0.0.0'
```

### image-automation/imageupdateautomation.yaml
```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: myapp
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: flux-bot
        email: flux@chenar.space
      messageTemplate: "chore(images): update myapp images"
    push:
      branch: main
  update:
    strategy: Setters
    path: ./apps/production/myapp   # or ./apps/private/myapp
```

### Tag your deployment image

In `deployment.yaml` add the setter comment so Flux knows which line to update:
```yaml
image: ghcr.io/chenarrr/myapp:v1.0.0 # {"$imagepolicy": "flux-system:myapp"}
```

### Promotion workflow

```
Push code → CI builds sha-abc123 tag → Flux ignores (not semver)
Test manually
git tag v1.0.0 && git push --tags
CI builds v1.0.0 tag → Flux sees it → commits updated image tag → cluster deploys
```

---

## Checklist

- [ ] Create folder + all yaml files
- [ ] Add app to parent `kustomization.yaml`
- [ ] Add secrets to Infisical Cloud under `/myapp` path
- [ ] Fill `YOUR_MACHINE_IDENTITY_ID` + `YOUR_PROJECT_SLUG` in InfisicalSecret
- [ ] Add DNS A record → Traefik LB IP
- [ ] Push to git
