# Adding a New App

Flux watches these folders:

```text
apps/production/   public, semver releases
apps/dev/          IP restricted, tracks main
apps/private/      IP restricted, internal tools
```

## Folder

```bash
mkdir -p apps/production/myapp/secrets
```

Expected files:

```text
apps/production/myapp/
├── kustomization.yaml
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── ingress.yaml
└── secrets/myapp-secrets.yaml
```

Use `apps/dev/myapp/` or `apps/private/myapp/` for those tiers.

## Namespace

`apps/production/myapp/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
```

## Ingress

`*.chenar.space` already points to Traefik.

`apps/production/myapp/ingress.yaml`

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

For dev/private, add this under the route:

```yaml
      middlewares:
        - name: private-access
          namespace: traefik
```

## Secrets

Create `/myapp` in Infisical Cloud first.

`apps/production/myapp/secrets/myapp-secrets.yaml`

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
      identityId: "bb4c4eec-3767-4447-a806-c079360125d0"
      autoCreateServiceAccountToken: true
      serviceAccountRef:
        name: infisical-service-account
        namespace: default
      secretsScope:
        projectSlug: "homelab-e-bm-i"
        envSlug: "prod"
        secretsPath: "/myapp"
        recursive: false
  managedKubeSecretReferences:
    - secretName: myapp-secrets
      secretNamespace: myapp
      creationPolicy: Owner
      template:
        includeAllSecrets: true
```

## App Kustomization

`apps/production/myapp/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secrets/myapp-secrets.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

Order matters: namespace first, secrets before deployment.

## Register with Flux

Edit `apps/production/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - echovote
  - portfolio
  - myapp
```

## Push

```bash
git add apps/production/myapp apps/production/kustomization.yaml
git commit -m "feat(apps): add myapp"
git push origin main
```

## Verify

```bash
flux get kustomization apps-production
kubectl get pods -n myapp -w
kubectl get secret myapp-secrets -n myapp
curl -I https://myapp.chenar.space
```

Debug Flux:

```bash
kubectl describe kustomization apps-production -n flux-system
```

Common failures:

```text
namespace missing   -> namespace.yaml order is wrong
secret missing      -> /myapp does not exist in Infisical
image pull failed   -> GHCR auth or image tag is wrong
ingress 404         -> service name or port is wrong
```

## Optional Image Automation

Add only if Flux should update image tags in git.

`apps/production/myapp/image-automation/imagerepositories.yaml`

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
    name: echovote-ghcr-auth
```

`apps/production/myapp/image-automation/imagepolicies.yaml`

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: myapp
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: myapp
  filterTags:
    pattern: '^v(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$'
    extract: '$major.$minor.$patch'
  policy:
    semver:
      range: '>=0.0.0'
```

Release:

```bash
git tag v1.0.0
git push origin v1.0.0
flux get image repository myapp -n flux-system
flux get image policy myapp -n flux-system
```
