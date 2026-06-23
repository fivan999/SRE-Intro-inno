# Lab 5 Submission — CI/CD & GitOps

> **Branch:** `feature/lab5` — вся работа по лабе только здесь. ArgoCD Application → `--revision feature/lab5`.

---

## Task 1 — CI Pipeline + ArgoCD Setup

### 5.1–5.2: CI workflow and ghcr.io images

**GitHub Actions run (green):**

https://github.com/fivan999/SRE-Intro-inno/actions/runs/28059578978

**Packages (`gh api user/packages?package_type=container`):**

```text
gh: Resource not accessible by personal access token (HTTP 403)
```

> **Manual proof:** GitHub → **Packages** → `quickticket-gateway`, `quickticket-events`, `quickticket-payments`.

### 5.3: K8s manifests use ghcr.io

`k8s/*.yaml`: `ghcr.io/fivan999/quickticket-*:<sha>`, `imagePullPolicy: Always`, `imagePullSecrets: ghcr-secret`.

### 5.4–5.5: ArgoCD + Application

```bash
argocd app create quickticket \
  --repo https://github.com/fivan999/SRE-Intro-inno.git \
  --path k8s \
  --revision feature/lab5 \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default \
  --sync-policy automated
```

**`argocd app get quickticket`:**

```text
Target:           feature/lab5
Sync Status:        Synced to feature/lab5 (18f3f70)
Health Status:      Healthy

apps   Deployment  default    gateway   Synced  Healthy
apps   Deployment  default    events    Synced  Healthy
apps   Deployment  default    payments  Synced  Healthy
apps   Deployment  default    postgres  Synced  Healthy
apps   Deployment  default    redis     Synced  Healthy
```

### 5.6: GitOps loop — version label v2

Commit on `feature/lab5`: `c001d71 feat: add version label v2 to gateway`

```bash
argocd app sync quickticket
kubectl get deployment gateway -o jsonpath='{.metadata.labels.version}{"\n"}'
```

```text
v2
```

### 5.7: kubectl edit with ArgoCD

Manual `kubectl edit` applies immediately, but ArgoCD detects drift on reconciliation and reverts to Git (automated sync) — Git is the source of truth.

---

## Task 2 — Rollback via GitOps

### 5.8: Bad deploy

```text
Sync Status:        Synced to feature/lab5 (faa3be8)
Health Status:      Progressing

gateway-6b58574449-7nbcs    0/1     ImagePullBackOff
```

### 5.9: git revert rollback

**`git log --oneline -3`:**

```text
9756171 Revert "feat: deploy new gateway version"
faa3be8 feat: deploy new gateway version
c001d71 feat: add version label v2 to gateway
```

**Recovery time after `git revert` + push:** 4 seconds

---

## Bonus — Automated Image Tag Update

```yaml
if: ${{ !startsWith(github.event.head_commit.message, 'ci:') }}
```

**Git log (code commit → CI tag-update):**

```text
c001d71 feat: add version label v2 to gateway
46a61da ci: update image tags to 57ddf6625152ff9cdbc53793258cfe408dbb6c58
20fbb2c feat(lab5): add CI pipeline and ghcr.io K8s manifests
```

**Image tag synced to cluster via ArgoCD:**

```text
ghcr.io/fivan999/quickticket-gateway:c001d71876599b8abaf10d5c89899ba0f894d965
```

---

## PR

`feature/lab5` → `main`, submit PR link in Moodle.
