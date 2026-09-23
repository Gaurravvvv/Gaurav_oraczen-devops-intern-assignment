# Notes API — DevOps Assignment Write-Up

This document covers my implementation for the Notes API DevOps assignment, walking through each part, explaining key design decisions, and answering the specific questions asked in `ASSIGNMENT.md`.

---

## Part 1 — Containerize the App

### Overview & Objectives
The goal of Part 1 is to package the FastAPI Notes API into an efficient, secure, and production-grade container image following all requirements from `ASSIGNMENT.md`:
- Multi-stage build (separating dependency installation from the runtime environment)
- Strict non-root execution (principle of least privilege)
- Pinned, slim base image (`python:3.12-slim`, avoiding `latest` and bloated default images)
- Sensible `.dockerignore` file
- Deliberate health check strategy (Docker `HEALTHCHECK` vs. Kubernetes probes)
- Lightweight final image size (~205 MB)

---

### Complete Dockerfile with Line-by-Line Breakdown

Here is the complete `app/Dockerfile` with detailed inline comments explaining the purpose of each instruction:

```dockerfile
# -------------------------------------------------------------
# Stage 1: Build stage
# Compiles and installs Python dependencies in an isolated layer.
# -------------------------------------------------------------
FROM python:3.12-slim AS builder

# Set the working directory for dependency installation
WORKDIR /app

# Copy ONLY requirements.txt first to take advantage of Docker layer caching.
# If source code changes but dependencies do not, Docker reuses this cached layer.
COPY requirements.txt .

# Install dependencies into ~/.local (user directory) without saving wheel caches.
# --no-cache-dir keeps image size lean by not caching download archives.
# --user isolates installed packages so they can easily be copied to the runtime stage.
RUN pip install --no-cache-dir --user -r requirements.txt


# -------------------------------------------------------------
# Stage 2: Runtime stage
# Clean, minimal Debian-slim image containing no build artifacts or caches.
# -------------------------------------------------------------
FROM python:3.12-slim

# Set application directory inside container
WORKDIR /app

# Security: Create a dedicated unprivileged user 'appuser' with UID 1000 and home directory.
# Running as root (UID 0) inside a container is a major security risk.
RUN useradd -u 1000 -m appuser

# Copy installed Python packages and binaries from builder stage into appuser's home
COPY --from=builder /root/.local /home/appuser/.local

# Copy application source code into container and assign ownership to appuser
COPY --chown=appuser:appuser . .

# Environment configuration:
# - Add ~/.local/bin to PATH so uvicorn and python CLI commands are directly executable.
# - Set PYTHONUNBUFFERED=1 to ensure stdout/stderr logs stream immediately (crucial for container log collectors).
ENV PATH=/home/appuser/.local/bin:$PATH \
    PYTHONUNBUFFERED=1

# Drop privileges: switch from root (UID 0) to appuser (UID 1000)
USER appuser

# Document that the container listens on port 8000
EXPOSE 8000

# Start FastAPI application using Uvicorn on all network interfaces (0.0.0.0) at port 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

---

### `.dockerignore` Configuration
To prevent sensitive files, temporary caches, and development environments from leaking into the container image, `app/.dockerignore` excludes:
```text
__pycache__
*.pyc
.venv
.env
.git
.pytest_cache
.ruff_cache
tests
```
**Benefits:**
1. **Faster build context upload**: Speeds up `docker build` by excluding large directories like `.git` and `.venv`.
2. **Security & isolation**: Prevents host virtual environments, `.env` files containing local secrets, or git commit history from being bundled into the production image.

---

### Technical Decisions & Trade-Offs

#### 1. Multi-Stage Build vs. Single Stage
- **Why**: Installing packages directly in a single stage leaves behind cached index files, setuptools artifacts, and build clutter.
- **Implementation**: The builder stage downloads and wheels dependencies into `/root/.local`. The runtime stage only takes `/home/appuser/.local` and the raw source code.
- **Outcome**: A clean runtime filesystem, fewer layers, and a significantly smaller attack surface.

#### 2. Non-Root User (`appuser`, UID 1000)
- **Why**: Running as `root` inside a container violates the principle of least privilege. In the event of a Remote Code Execution (RCE) vulnerability in application dependencies (e.g. FastAPI/Starlette), an attacker would obtain root privileges. If container isolation fails, this can lead to host breakout.
- **Implementation**: `useradd -u 1000 -m appuser` creates a predictable UID and home directory. Files are assigned ownership via `COPY --chown=appuser:appuser`, and runtime execution is enforced via `USER appuser`. This satisfies Kubernetes `runAsNonRoot: true` policies.

#### 3. Pinned Base Image (`python:3.12-slim`) & Debian vs. Alpine
- **Avoided `latest`**: `latest` is non-deterministic; builds today could break tomorrow if upstream changes.
- **Avoided full `python:3.12`**: The standard image includes complete compilers and packages, weighing over 1 GB.
- **Why Debian-slim over Alpine?**: While Alpine is marginally smaller, Python packages with C extensions (such as `psycopg2-binary`) often encounter compatibility issues and subtle segmentation faults when linked against Alpine's `musl libc` instead of GNU `glibc`. Debian `slim` offers full compatibility with `glibc` wheels while remaining compact (~205 MB).

#### 4. Docker `HEALTHCHECK` vs. Kubernetes Probes
- **The Question**: `ASSIGNMENT.md` asks for: *"A HEALTHCHECK instruction, or explain in your write-up why you'd rely on Kubernetes probes instead"*.
- **The Rationale**: We intentionally rely on Kubernetes `livenessProbe` and `readinessProbe` instead of Docker's built-in `HEALTHCHECK`:
  - **Ignored by Orchestrator**: The Kubernetes `kubelet` completely ignores container-level Docker `HEALTHCHECK` instructions and only evaluates probe endpoints defined in the Kubernetes pod spec.
  - **Separation of Liveness vs. Readiness**:
    - **Liveness (`/healthz`)**: Checks if the web process is running. If it deadlocks, Kubernetes restarts the pod.
    - **Readiness (`/readyz`)**: Checks if the database is reachable (`SELECT 1`). If Postgres is temporarily starting up or restarting, the readiness probe fails and Kubernetes stops routing traffic to the pod without killing it. Docker's single `HEALTHCHECK` cannot distinguish between these two states.

#### 5. Image Size Verification
- The resulting container image measures **205 MB**, well below bloated typical Python images (>1 GB) and fast to pull across CI and Kubernetes nodes.

---

### Verification Commands & Results

```bash
# 1. Build the local image
docker build -t notes-api:local app

# 2. Check image size
docker images notes-api:local
# Output:
# REPOSITORY    TAG       IMAGE ID       CREATED          SIZE
# notes-api     local     a9b3c4d5e6f7   2 minutes ago    205MB

# 3. Verify non-root user execution
docker run --rm notes-api:local whoami
# Output: appuser

docker run --rm notes-api:local id
# Output: uid=1000(appuser) gid=1000(appuser) groups=1000(appuser)

# 4. Verify local execution with environment variables
docker run --rm -p 8000:8000 \
  -e POSTGRES_HOST=host.docker.internal \
  -e POSTGRES_PASSWORD=notes \
  notes-api:local
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
        name: {{ .Release.Name }}-postgresql
        key: password
```

Non-sensitive connection parameters (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`) are stored in a `ConfigMap` and loaded into the pod via `envFrom`:

```yaml
envFrom:
  - configMapRef:
      name: {{ .Release.Name }}-notes-api-config
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

### Verification & Live Deployment Proof

The deployment was verified on a local multi-node Kind cluster with ArgoCD. Below are the verification screenshots:

#### 1. Cluster & ArgoCD Setup
- **Kind Cluster**: Multi-node Kind cluster initialized and ready:
  ![Kind Cluster Ready](images/Kind_Cluster%20Created.png)

- **ArgoCD Installation**: ArgoCD core controllers and services running in `argocd` namespace:
  ![ArgoCD Initiated](images/Initiated_ArgoCD.png)

- **Access & Credentials**: Port-forwarding ArgoCD server and retrieving the admin password:
  ![Port Forward and Admin Secret](images/Port_Forward&Retrieving_Pass.png)

#### 2. GitOps Deployment & Application Topology
- **ArgoCD Sync**: `notes-api-dev` Application deployed in `notes-dev` namespace showing **Synced** and **Healthy**:
  ![ArgoCD Success](images/ArgoCD_Success.png)

- **Resource Topology**: Full resource tree showing the Deployment, Service, ConfigMap, and Bitnami PostgreSQL subchart:
  ![ArgoCD Resource Diagram](images/ArgoCD_Success_Diagram.png)

#### 3. Pod Status & Health
- **Pod Status**: Both `notes-api` and `postgresql-0` pods running cleanly (`1/1 Running`):
  ![All Pods Running](images/All_Pods_Running.png)

#### 4. End-to-End API & Database Verification
- **Readiness Probe**: `/readyz` endpoint returning HTTP 200 with database connected:
  ![Readiness OK](images/ReadinessOK.png)

- **API & Data Persistence**: Testing note creation and retrieval (`POST /notes`, `GET /notes`) returning HTTP 200/201:
  ![Status Code OK](images/Status_CodeOK.png)

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
