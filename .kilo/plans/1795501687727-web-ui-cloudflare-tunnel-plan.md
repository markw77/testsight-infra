# Plan: Basic Web UI App with Cloudflare Quick Tunnel

## Objective
Deploy a simple nginx web UI app accessible via Cloudflare quick tunnel (trycloudflare.com), managed by Argo CD from the app repo.

## Architecture
```
Internet → Cloudflare (trycloudflare.com) → cloudflared (in cluster) → web-ui Service (ClusterIP) → nginx pods
```

## Components

### 1. Web UI Application (`web-ui.yaml`)
- **Namespace:** `testsight-system` (already exists, allowed by AppProject)
- **Deployment:** `nginx:alpine` serving static HTML
- **Service:** `ClusterIP` on port 80 (internal only)
- **Replicas:** 1 (simple demo)

### 2. Cloudflare Tunnel (`cloudflared.yaml`)
- **Namespace:** `testsight-system`
- **Deployment:** `cloudflare/cloudflared:latest` with quick tunnel flag
- **Args:** `tunnel --no-autoupdate --url http://web-ui.testsight-system.svc.cluster.local:80`
- **Logs:** Show trycloudflare.com hostname on startup

### 3. Argo CD Applications
Both manifests go in `~/testsight/deploy/argocd/apps/`:
- `web-ui.yaml` - the web app
- `cloudflared.yaml` - the tunnel

Root app (`testsight-root`) has `syncPolicy.automated.prune: true` - will auto-sync new apps.

## Files to Create

```
~/testsight/deploy/argocd/apps/
├── web-ui.yaml          # Deployment + Service + ConfigMap (HTML)
└── cloudflared.yaml     # Deployment for cloudflared quick tunnel
```

## Implementation Details

### web-ui.yaml
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: web-ui
  namespace: argocd
spec:
  project: testsight
  source:
    repoURL: https://github.com/markw77/testsight.git
    targetRevision: main
    path: deploy/argocd/apps/web-ui
  destination:
    server: https://kubernetes.default.svc
    namespace: testsight-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Kubernetes manifests** in `deploy/argocd/apps/web-ui/` (or inline in the Application via `source.path` pointing to a directory with Kustomize/Helm/plain manifests).

Simpler: inline the Deployment + Service + ConfigMap directly in the Application manifest using `source.path` as a directory with plain YAML files.

### cloudflared.yaml
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudflared
  namespace: argocd
spec:
  project: testsight
  source:
    repoURL: https://github.com/markw77/testsight.git
    targetRevision: main
    path: deploy/argocd/apps/cloudflared
  destination:
    server: https://kubernetes.default.svc
    namespace: testsight-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Validation Steps
1. Commit both Application manifests to `~/testsight/deploy/argocd/apps/`
2. Push to `markw77/testsight` main branch
3. Argo CD root app auto-syncs children
4. Check `kubectl -n testsight-system logs deploy/cloudflared -f | grep trycloudflare` for public URL
5. Access the URL - should show nginx welcome page

## Open Questions (Resolved)
- ✅ Tunnel type: Quick tunnel (trycloudflare.com)
- ✅ Domain: No, use quick tunnel
- ✅ Image: nginx:alpine
- ✅ Namespace: testsight-system
- ✅ Exposure: Cloudflare Tunnel only (no LoadBalancer)