# Notes API — DevOps Assignment Write-Up

This document covers my implementation for the Notes API DevOps assignment, walking through each part, explaining key design decisions, and answering the specific questions asked in `ASSIGNMENT.md`.

---

## Part 1 — Containerize the App

### What I Built
- Created `app/Dockerfile` and `app/.dockerignore`.
- Built a multi-stage Docker image using `python:3.12-slim`:
  - **Builder stage**: Installs the dependencies from `requirements.txt` into `~/.local` with `--user` and `--no-cache-dir`.
  - **Runtime stage**: Uses a fresh `python:3.12-slim` image, creates a non-root user `appuser` (UID 1000), copies only `~/.local` and the application code, and sets `USER appuser`.

### Decisions & Trade-offs
- **Non-root user**: Running as `appuser` (UID 1000) ensures the container does not run as `root`, following the principle of least privilege and preventing potential container breakout risks.
- **Pinned base image**: Used `python:3.12-slim` instead of `python:3.12` (which is >1GB) or `latest` (which is non-deterministic). I chose Debian slim over Alpine because Python packages with C extensions (like `psycopg2-binary`) can sometimes have compatibility issues with `musl` on Alpine.
- **Docker HEALTHCHECK vs. Kubernetes Probes**: I rely on Kubernetes `livenessProbe` and `readinessProbe` for health checking rather than Docker's `HEALTHCHECK`. In Kubernetes, the kubelet completely ignores Docker's container-level `HEALTHCHECK` instruction and only respects the pod-level probes defined in the manifest. Having separate liveness (`/healthz`) and readiness (`/readyz`) probes in Kubernetes allows the cluster to distinguish between a process that has crashed (needs a restart) and a process that is temporarily waiting on the database (should not receive traffic yet).
- **Image Size**: The final image size is **205 MB**, which is small and fast to pull in CI/CD.

### Verification Commands
```bash
# Build the image
docker build -t notes-api:local app

# Verify non-root user
docker run --rm notes-api:local whoami
# Output: appuser

docker run --rm notes-api:local id
# Output: uid=1000(appuser) gid=1000(appuser) groups=1000(appuser)
```

---

## Part 2 — Helm Chart with Database Dependency

### What I Built
A Helm chart under `helm/notes-api/` with:
- `Chart.yaml`: Declares `bitnamicharts/postgresql` (v15.5.37 via OCI) as a dependency.
- `templates/`: `deployment.yaml`, `service.yaml`, `configmap.yaml`, `serviceaccount.yaml`, `hpa.yaml`, `ingress.yaml`, `_helpers.tpl`, and `NOTES.txt`.
- `values.yaml`: Base defaults.
- `values-dev.yaml`: Overrides for development.
- `values-prod.yaml`: Overrides for production.

### How the Subchart's Secret is Wired (Crucial Check)
The `bitnami/postgresql` subchart automatically creates a Kubernetes Secret named `<release-name>-postgresql` containing the database password under the key `password`.

Instead of duplicating the password in plaintext in `values.yaml`, the app's `Deployment` reads the password directly from the subchart's Secret using `secretKeyRef`:

```yaml
env:
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: {{ include "notes-api.postgresqlSecretName" . }}
        key: password
```

Non-sensitive connection parameters (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`) are stored in a `ConfigMap` and loaded into the pod via `envFrom`:

```yaml
envFrom:
  - configMapRef:
      name: {{ include "notes-api.fullname" . }}-config
```

The database host defaults to `{{ .Release.Name }}-postgresql`, which matches the service name created by the Bitnami subchart. This keeps secrets out of git and decouples sensitive credentials from application configuration.

### Environment Overrides: `values-dev.yaml` vs. `values-prod.yaml`
Instead of duplicating the whole file, only the fields that meaningfully differ between environments are overridden:

| Field | `values-dev.yaml` | `values-prod.yaml` | Reason |
|---|---|---|---|
| `replicaCount` | `1` | `3` | Dev saves resources; Prod needs high availability. |
| `image.tag` | `dev` | `1.0.0` | Dev uses floating tag; Prod uses immutable release tag. |
| `image.pullPolicy` | `IfNotPresent` | `Always` | Dev uses local cache; Prod always pulls latest release. |
| `resources` | Low (`50m` CPU / `64Mi` RAM) | Higher (`250m` CPU / `256Mi` RAM) | Sized according to workload expectations. |
| `postgresql.primary.persistence.enabled` | `false` | `true` (`10Gi`) | Dev database can be ephemeral; Prod requires persistent storage. |
| `autoscaling.enabled` | `false` | `true` (3-10 replicas) | Prod scales automatically under traffic spikes. |

### Verification Commands
```bash
# Build subchart dependencies
helm dependency build helm/notes-api

# Lint the chart
helm lint helm/notes-api
# Output: 1 chart(s) linted, 0 chart(s) failed

# Verify template rendering for dev and prod
helm template notes-dev helm/notes-api -f helm/notes-api/values-dev.yaml
helm template notes-prod helm/notes-api -f helm/notes-api/values-prod.yaml
```

---

## Part 3 — CI Pipeline (GitHub Actions)

### What I Built
A GitHub Actions workflow in `.github/workflows/ci.yaml` that triggers on pull requests and pushes to `main`:

1. **`lint`**:
   - Sets up Python 3.12.
   - Installs dependencies and `ruff`.
   - Runs `ruff check app/` to check code style and enforce linting standards.
2. **`docker-build-scan`**:
   - Builds the Docker image tagged with the commit SHA and `latest`.
   - Runs `aquasecurity/trivy-action` in `image` mode to scan for vulnerabilities.
   - **Severity Gate**: Fails the pipeline (`exit-code: 1`) on any `CRITICAL` or `HIGH` vulnerabilities.
   - **Registry Push**: On merges to `main`, logs in to GitHub Container Registry (GHCR) and pushes the scanned image.
3. **`helm-lint-scan`**:
   - Installs Helm v3.
   - Runs `helm dependency build` and `helm lint`.
   - Renders the manifests using `helm template` and runs Trivy in `config` mode to scan for Kubernetes misconfigurations (e.g. containers running as root, missing limits).

---

## Part 4 — GitOps with ArgoCD

### What I Built
ArgoCD `Application` manifests:
- `argocd/notes-api-dev.yaml`: Targets namespace `notes-dev`, applying `values.yaml` and `values-dev.yaml`.
- `argocd/notes-api-prod.yaml`: Targets namespace `notes-prod`, applying `values.yaml` and `values-prod.yaml`.

### Sync Policy: Dev vs. Prod
- **Dev (`prune: true, selfHeal: true`)**:
  In dev, automatic pruning is enabled so that if an engineer removes a resource (like a temporary service or ingress), ArgoCD immediately cleans it up from the cluster. `selfHeal` fixes any manual drift.
- **Prod (`prune: false, selfHeal: true`)**:
  In prod, `prune` is intentionally set to `false`. Auto-pruning in production is dangerous: a bad commit or accidental deletion of a manifest in git could immediately delete a PVC or database in the cluster. Setting `prune: false` ensures deletions require manual confirmation, while `selfHeal: true` still restores any accidental manual changes back to the git state.

### Sequence of Events: From Merge to Running Pod
When a developer edits `values-prod.yaml` and merges to `main`:

1. **Git Merge**: The commit is merged to `main`.
2. **ArgoCD Detection**: ArgoCD detects the new commit (either via its 3-minute polling loop or immediately via a GitHub webhook).
3. **Diff Calculation**: ArgoCD renders the Helm chart using the updated `values-prod.yaml` and compares the output with the live cluster state in etcd. The application state becomes `OutOfSync`.
4. **Sync / Reconciliation**: ArgoCD applies the changes via the Kubernetes API server, updating the `Deployment` spec.
5. **Rolling Update**: The Kubernetes Deployment controller notices the updated spec and creates a new `ReplicaSet`.
6. **Pod Scheduling**: The new pods are scheduled and started by kubelet.
7. **Readiness Probe**: Kubelet waits for the container to start and checks `/readyz`. Once `/readyz` returns 200 (database connection is established), the pod is marked `Ready`.
8. **Traffic Cutover**: The Kubernetes Service routes traffic to the new pod, and the old pod is gracefully terminated.
9. **Synced & Healthy**: ArgoCD observes that all pods are ready and marks the application as `Synced` and `Healthy`.

### Where to Look if It Didn't Roll Out
If the rollout fails or gets stuck:
1. **ArgoCD UI / CLI**: Check `argocd app get notes-api-prod`. Is the app `OutOfSync` or `Degraded`? The UI shows the exact error (e.g. Helm rendering error or git repo authentication failure).
2. **Kubernetes Deployment Events**: Run `kubectl describe deployment notes-prod-notes-api -n notes-prod` to see if the deployment controller was able to create the new ReplicaSet or if it was blocked (e.g., quota exceeded).
3. **Pod Status**: Run `kubectl get pods -n notes-prod`.
   - If `Pending`: Check `kubectl describe pod <name>` for scheduling issues (insufficient CPU/memory or missing PVC).
   - If `ImagePullBackOff`: Check if the image tag exists in the registry.
   - If `CrashLoopBackOff`: Check `kubectl logs <name> -n notes-prod --previous` to see application error logs.
4. **Probe Failures**: If the pod stays in `0/1 Running`, check `kubectl describe pod <name>`. If `/readyz` is failing, check if Postgres is running and whether `POSTGRES_PASSWORD` in the secret matches.

---

## Part 5 — Stretch Proposals (Optional)

### 1. Secrets Management Proposal (External Secrets Operator + AWS Secrets Manager)
In a real production environment on AWS EKS:
- **Approach**: Use **External Secrets Operator (ESO)** with **AWS Secrets Manager**.
- **Why**: Storing passwords in git (even encoded) is insecure. With ESO:
  - Secrets are created and managed in AWS Secrets Manager.
  - The EKS cluster runs ESO, which authenticates to AWS using **IAM Roles for Service Accounts (IRSA)** (no static AWS keys).
  - An `ExternalSecret` manifest in git tells ESO to fetch `production/notes-api/db` and automatically generate a native Kubernetes Secret.
  - The Helm chart and ArgoCD remain unchanged because the app continues reading from the Kubernetes Secret via `secretKeyRef`.

### 2. Monitoring Hooks
- **Prometheus Scrape Annotations**: Added to the pod template in `deployment.yaml`:
  ```yaml
  prometheus.io/scrape: "true"
  prometheus.io/port: "8000"
  prometheus.io/path: "/healthz"
  ```
- **ServiceMonitor & Alerts**: In a cluster with Prometheus Operator, a `ServiceMonitor` would target the `notes-api` service. Recommended alerts:
  1. **High Error Rate**: Alert if 5xx responses exceed 5% over 5 minutes.
  2. **Readiness Flapping**: Alert if ready pods drop below 1 for more than 2 minutes.
  3. **High Latency**: Alert if p95 response time exceeds 500ms over 5 minutes.

### 3. Autoscaling (HPA)
- Added `templates/hpa.yaml` in the chart, enabled via `.Values.autoscaling.enabled`.
- In `values-prod.yaml`, HPA is configured with `minReplicas: 3`, `maxReplicas: 10`, and target CPU utilization of 75%.
- To test under load:
  ```bash
  # Generate traffic using a load tool (e.g. hey or ab)
  hey -n 10000 -c 50 http://localhost:8000/healthz

  # Watch HPA scale pods
  kubectl get hpa -w
  ```

### 4. Image Supply Chain Security
- **SBOM**: Trivy can generate a Software Bill of Materials in CycloneDX format during CI (`trivy image --format cyclonedx -o sbom.json <image>`) to keep track of all third-party libraries and dependencies.
- **Image Signing**: In CI, we can use `cosign` with GitHub Actions OIDC (keyless signing) to sign the container image digest before deploying. A Kubernetes admission controller (like Kyverno or Sigstore Policy Controller) can then reject any images that are not signed by our CI workflow.
