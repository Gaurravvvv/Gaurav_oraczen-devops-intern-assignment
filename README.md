# Notes API — DevOps Assignment Implementation

**Author:** Gaurav Vibhandik  
**LinkedIn:** [linkedin.com/in/gaurravvvv](https://www.linkedin.com/in/gaurravvvv/) | **LeetCode:** [leetcode.com/u/bis9NoCqXN](https://leetcode.com/u/bis9NoCqXN/)

This repository contains my complete implementation for the Notes API DevOps assignment. Below is the step-by-step walkthrough of how I built, tested, and verified each task from Part 1 to Part 4.

> Detailed design decisions, trade-offs, and screenshots are documented in **[WRITEUP.md](WRITEUP.md)**.

---

## Tech Stack

- **FastAPI (Python 3.12)** — Backend application
- **Docker** — Multi-stage containerization
- **Helm v3** — Kubernetes packaging
- **Kind** — Local Kubernetes cluster
- **GitHub Actions** — CI pipeline
- **Trivy** — Vulnerability & IaC security scanning
- **GHCR** — Container registry
- **ArgoCD** — GitOps deployment

---

## Prerequisites & Local Tooling Setup (`.bin`)

To keep local tools isolated without polluting system-wide paths, standalone binaries for `kind` and `helm` were placed in a `.bin/` folder (configured in `.gitignore`):

### Commands:
```bash
# 1. Create a local .bin folder
mkdir .bin

# 2. Download Kind (Windows)
curl -Lo .bin/kind.exe https://kind.sigs.k8s.io/dl/v0.24.0/kind-windows-amd64.exe

# 3. Download Helm (Windows)
# Download from https://get.helm.sh or winget install Helm.Helm and place helm.exe into .bin/

# 4. Add .bin to session PATH
$env:PATH = "$PWD\.bin;" + $env:PATH    # PowerShell
# set PATH=%CD%\.bin;%PATH%             # CMD

# 5. Verify versions
kind version
helm version
```

---

## Step 1: Containerizing the Application (Part 1)

I containerized the FastAPI application using a multi-stage Docker build to keep the image small and secure.

### What I did:
- Created `app/Dockerfile` with a builder stage (to install Python packages into `~/.local`) and a minimal runtime stage based on `python:3.12-slim`.
- Created an unprivileged user `appuser` (UID 1000) so the container never runs as root.
- Created `app/.dockerignore` to keep virtual environments, git files, and cache files out of the image.

### Commands :
```bash
# 1. Built the Docker image locally
docker build -t notes-api:local app

# 2. Verified that the container runs as non-root
docker run --rm notes-api:local whoami
# Output: appuser

docker run --rm notes-api:local id
# Output: uid=1000(appuser) gid=1000(appuser) groups=1000(appuser)

# 3. Checked image size (measures ~205MB)
docker images notes-api:local
```

---

## Step 2: Creating the Helm Chart with Database Dependency (Part 2)

I packaged the application into a Helm chart under `helm/notes-api/` and consumed a community PostgreSQL chart as a subchart dependency.

### What I did:
- Declared PostgreSQL subchart dependency in `Chart.yaml`.
- Wired the database password directly from the subchart's generated Secret (`{{ .Release.Name }}-postgresql`, key `password`) via `secretKeyRef` in `deployment.yaml` so no passwords exist in plaintext in git.
- Split configuration between base defaults (`values.yaml`), development overrides (`values-dev.yaml` — 1 replica, ephemeral storage), and production overrides (`values-prod.yaml` — 3 replicas, 10Gi persistent disk, HPA enabled).
- Added `hpa.yaml` for autoscaling and `NOTES.txt` for post-install instructions.

### Commands :
```bash
# 1. Downloaded and built the PostgreSQL subchart dependency
helm dependency build helm/notes-api

# 2. Linted the chart to verify template syntax and packaging
helm lint helm/notes-api
# Output: 1 chart(s) linted, 0 chart(s) failed

# 3. Verified rendered manifests for dev and prod
helm template notes-dev helm/notes-api -f helm/notes-api/values-dev.yaml
helm template notes-prod helm/notes-api -f helm/notes-api/values-prod.yaml
```

---

## Step 3: Automated CI Pipeline with GitHub Actions (Part 3)

Built a GitHub Actions workflow in `.github/workflows/ci.yaml` that runs automatically on pull requests and pushes to `main`.

### What I did:
- **Lint job**: Installs dependencies and runs `ruff check app/` to enforce Python code quality.
- **Docker Build & Scan job**: Builds the image tagged with the commit SHA, runs Trivy vulnerability scan with a strict severity gate (`exit-code: 1` on `CRITICAL,HIGH`), and pushes the verified image to GitHub Container Registry (GHCR) on `main`.
- **Helm Lint & Scan job**: Builds chart dependencies, lints the chart, renders manifests, and runs Trivy in `config` mode with a strict severity gate (`exit-code: 1` on `CRITICAL,HIGH`) to catch and block Kubernetes misconfigurations.

### Verification:
All three jobs run in parallel and pass cleanly in GitHub Actions (see green status in `WRITEUP.md`).

---

## Step 4: GitOps Deployment with ArgoCD (Part 4)

I deployed the application using GitOps with ArgoCD on a local multi-node Kind cluster.

### What I did:
- Created ArgoCD Application manifests for development (`argocd/notes-api-dev.yaml`) and production (`argocd/notes-api-prod.yaml`).
- Configured sync policies: enabled automated pruning in Dev for fast cleanup, disabled pruning in Prod to protect persistent data and secrets, and enabled `selfHeal` across both to prevent manual drift.

### Commands :
```bash
# 1. Created the local Kind cluster
kind create cluster --name notes-cluster

# 2. Installed ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Deployed the application via ArgoCD
kubectl apply -f argocd/notes-api-dev.yaml

# 4. Verified pod status (both app and postgresql running 1/1)
kubectl get pods -n notes-dev
# Output:
# notes-api-dev-notes-api-xxxx   1/1   Running
# notes-api-dev-postgresql-0    1/1   Running

# 5. Port-forwarded the service to test locally
kubectl port-forward svc/notes-api-dev-notes-api -n notes-dev 8000:8000

# 6. Tested health and readiness probes
curl http://localhost:8000/healthz   # {"status":"ok"}
curl http://localhost:8000/readyz    # {"status":"ready"}

# 7. Tested database CRUD functionality
curl -X POST http://localhost:8000/notes \
  -H "Content-Type: application/json" \
  -d '{"title":"First Note","content":"Deployed via ArgoCD"}'

curl http://localhost:8000/notes
```

---

## Project Structure

```
├── .github/workflows/
│   └── ci.yaml                  # GitHub Actions CI pipeline (Lint, Trivy, GHCR push)
├── app/
│   ├── Dockerfile               # Multi-stage, non-root Python 3.12 containerfile
│   ├── .dockerignore            # Build context exclusions
│   ├── main.py                  # FastAPI application code
│   └── requirements.txt         # Pinned Python dependencies
├── argocd/
│   ├── notes-api-dev.yaml       # ArgoCD Application manifest for dev
│   └── notes-api-prod.yaml      # ArgoCD Application manifest for prod
├── helm/notes-api/
│   ├── Chart.yaml               # Chart metadata & PostgreSQL subchart dependency
│   ├── values.yaml              # Base configuration defaults
│   ├── values-dev.yaml          # Development environment overrides
│   ├── values-prod.yaml         # Production environment overrides
│   └── templates/               # Kubernetes Deployment, Service, ConfigMap, HPA
├── images/                      # Execution and verification screenshots
├── README.md                    # Step-by-step implementation guide
└── WRITEUP.md                   # Full design rationale, trade-offs, and answers
```

---

## Author

- **Name:** Gaurav Vibhandik
- **LinkedIn:** [linkedin.com/in/gaurravvvv](https://www.linkedin.com/in/gaurravvvv/)
- **LeetCode:** [leetcode.com/u/bis9NoCqXN](https://leetcode.com/u/bis9NoCqXN/)

