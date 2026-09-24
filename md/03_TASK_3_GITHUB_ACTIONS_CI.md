# Task 3 Deep-Dive: GitHub Actions CI Pipeline & Security Gates

This document provides a line-by-line technical breakdown of the CI pipeline implemented in `.github/workflows/ci.yaml`. It details **what each line means**, **what its work is**, **why we used it**, and **how it works under the hood**, followed by DevSecOps principles and likely Round 3 interview questions.

---

## 1. Complete Workflow Architecture

The CI pipeline runs automatically on pull requests and pushes to `main`. It is split into **three independent parallel jobs**:
1. **`lint`**: Validates Python code quality with Ruff.
2. **`docker-build-scan`**: Builds the container, runs Trivy vulnerability scanning with a strict blocking gate, and publishes to GitHub Container Registry (GHCR).
3. **`helm-lint-scan`**: Validates Helm chart syntax, renders production manifests, and executes a Trivy IaC configuration scan with a strict blocking gate.

```text
[ Push / PR Event to main ]
          │
          ├───► Job 1: lint (Python 3.12 + Ruff)
          │
          ├───► Job 2: docker-build-scan (Build -> Trivy Image Scan (exit 1) -> GHCR Push)
          │
          └───► Job 3: helm-lint-scan (Helm Lint -> Template Render -> Trivy IaC Scan (exit 1))
```

---

## 2. Line-by-Line Breakdown of `.github/workflows/ci.yaml`

```yaml
1: name: CI
2: 
3: on:
4:   push:
5:     branches: [ main ]
6:     paths-ignore:
7:       - '**.md'
8:       - 'images/**'
9:       - '.gitignore'
10:   pull_request:
11:     branches: [ main ]
12:     paths-ignore:
13:       - '**.md'
14:       - 'images/**'
15:       - '.gitignore'
```

### Lines 1–16: Workflow Triggers & Path Filtering
* **Line 1 (`name: CI`):** The display name shown in GitHub's Actions tab and commit status badges.
* **Line 3–5 & 10–11 (`on.push` & `on.pull_request` on `branches: [ main ]`):**
  * *What it means:* Triggers the pipeline on direct commits to `main` and on pull requests targeting `main`.
  * *Why we used it:* Guarantees that all PRs are validated before merging, and that the main branch builds and publishes tested container images.
* **Line 6–9 & 12–15 (`paths-ignore`):**
  * *What it means:* Instructs GitHub Actions **not** to trigger the workflow if a commit only modifies markdown documentation (`**.md`), verification screenshots (`images/**`), or `.gitignore`.
  * *Why we used it (Cost & Resource Optimization):*
    1. Prevents wasting GitHub Actions runner compute minutes on documentation updates.
    2. Prevents creating unnecessary Docker builds and GHCR image tags when only a README typo is fixed.

---

### Lines 17–34: Job 1 — `lint`

```yaml
17: jobs:
18:   lint:
19:     runs-on: ubuntu-latest
20:     steps:
21:       - uses: actions/checkout@v4
22: 
23:       - uses: actions/setup-python@v5
24:         with:
25:           python-version: "3.12"
26: 
27:       - name: Install dependencies
28:         run: |
29:           pip install -r app/requirements.txt
30:           pip install ruff
31: 
32:       - name: Lint with Ruff
33:         run: ruff check app/ --ignore B008,F401,I001,UP045
```

* **Line 19 (`runs-on: ubuntu-latest`):** Provisions a fresh, ephemeral virtual machine running Ubuntu Linux hosted by GitHub.
* **Line 21 (`uses: actions/checkout@v4`):** Clones the Git repository into the runner's workspace (`/home/runner/work/...`).
* **Line 23–25 (`uses: actions/setup-python@v5` with `python-version: "3.12"`):**
  * Downloads and adds Python 3.12 to the runner's system `PATH`.
* **Line 27–30 (`Install dependencies`):**
  * Installs the application requirements and the `ruff` linter.
* **Line 32–33 (`Lint with Ruff`):**
  * *What it does:* Executes Ruff against all Python files in `app/`.
  * *Why Ruff:* Ruff is written in Rust and is 10 to 100 times faster than Flake8 or Black. It catches syntax errors, unhandled exceptions, and dead code in milliseconds.
  * *Why specific rules were ignored:*
    * `B008` (Do not perform function call in argument defaults): FastAPI relies on `Depends(...)` in route parameters (e.g. `db: Session = Depends(get_db)`). B008 would flag this standard FastAPI pattern as a violation.
    * `F401`: Allows clean model exports in `__init__.py` files.
    * `I001` & `UP045`: Skips strict import sorting and legacy typing warnings.

---

### Lines 35–74: Job 2 — `docker-build-scan`

```yaml
35:   docker-build-scan:
36:     runs-on: ubuntu-latest
37:     permissions:
38:       contents: read
39:       packages: write
40:     steps:
41:       - uses: actions/checkout@v4
42: 
43:       - name: Set lowercased image name
44:         run: |
45:           IMAGE_NAME="ghcr.io/${{ github.repository }}/notes-api"
46:           echo "IMAGE_NAME=$(echo $IMAGE_NAME | tr '[:upper:]' '[:lower:]')" >> $GITHUB_ENV
47: 
48:       - name: Build Docker image
49:         run: |
50:           docker build -t ${{ env.IMAGE_NAME }}:${{ github.sha }} -t ${{ env.IMAGE_NAME }}:latest app
51: 
52:       - name: Run Trivy vulnerability scan
53:         uses: aquasecurity/trivy-action@master
54:         with:
55:           image-ref: ${{ env.IMAGE_NAME }}:${{ github.sha }}
56:           format: 'table'
57:           exit-code: '1'
58:           ignore-unfixed: true
59:           severity: 'CRITICAL,HIGH'
60: 
61:       - name: Log in to GitHub Container Registry
62:         if: github.ref == 'refs/heads/main'
63:         uses: docker/login-action@v3
64:         with:
65:           registry: ghcr.io
66:           username: ${{ github.actor }}
67:           password: ${{ secrets.GITHUB_TOKEN }}
68: 
69:       - name: Push Docker image to GHCR
70:         if: github.ref == 'refs/heads/main'
71:         run: |
72:           docker push ${{ env.IMAGE_NAME }}:${{ github.sha }}
73:           docker push ${{ env.IMAGE_NAME }}:latest
```

* **Line 37–39 (`permissions`):**
  * `contents: read`: Allows cloning the repository.
  * `packages: write`: Grants the workflow token permission to upload and publish container packages to GitHub Container Registry (GHCR). Following the principle of least privilege, other scopes (like issues or pull requests) are denied.
* **Line 43–46 (`Set lowercased image name`):**
  * *The Problem:* GitHub repository paths often contain uppercase letters (e.g. `Gaurravvvv/Gaurav_oraczen...`). However, the Docker/OCI image specification **strictly prohibits uppercase letters** in image registry names. Attempting to build or push an image with uppercase characters fails with `invalid reference format`.
  * *The Fix:* We pipe the string through `tr '[:upper:]' '[:lower:]'` and append it to `$GITHUB_ENV`.
* **Line 48–50 (`Build Docker image` with Multi-Tagging):**
  * Builds `app/Dockerfile` and applies **two tags**:
    1. `${{ env.IMAGE_NAME }}:${{ github.sha }}`: An **immutable tag** tied to the exact Git commit SHA. This provides provenance: you can trace any running container in the cluster directly back to the exact code commit that built it.
    2. `${{ env.IMAGE_NAME }}:latest`: A **convenience pointer tag** used in development environments.
* **Line 52–60 (`Run Trivy vulnerability scan`):**
  * *`image-ref`*: Directs Trivy to scan the image tagged with the commit SHA.
  * *`format: 'table'`*: Outputs human-readable vulnerability reports directly in the GitHub Actions console.
  * *`exit-code: '1'` (The Strict Gate):* If Trivy finds any vulnerability matching the criteria, it terminates with return code 1. This fails the GitHub Action immediately, blocking subsequent steps and preventing the image from being pushed.
  * *`severity: 'CRITICAL,HIGH'`*: Focuses on exploitable, severe security flaws rather than low-priority warnings.
  * *`ignore-unfixed: true` (Pragmatic DevSecOps):* Ignores CVEs where the upstream Linux distribution vendor has not yet released a patch. Failing builds on vulnerabilities that developers cannot fix halts deployments without improving security.
* **Line 61–68 (`Log in to GHCR`):**
  * Authenticates using the automatic `${{ secrets.GITHUB_TOKEN }}`. Does not require manually generating or rotating personal access tokens (PATs).
  * `if: github.ref == 'refs/heads/main'`: Only logs in on pushes to `main`. Pull requests from forks or feature branches are not allowed to push images.
* **Line 69–74 (`Push Docker image to GHCR`):**
  * Pushes both the SHA tag and the `latest` tag to GHCR, making them available for ArgoCD and Kubernetes.

---

### Lines 75–101: Job 3 — `helm-lint-scan`

```yaml
75:   helm-lint-scan:
76:     runs-on: ubuntu-latest
77:     steps:
78:       - uses: actions/checkout@v4
79: 
80:       - uses: azure/setup-helm@v4
81:         with:
82:           version: v3.17.1
83: 
84:       - name: Build dependencies & lint chart
85:         run: |
86:           helm dependency build helm/notes-api
87:           helm lint helm/notes-api
88: 
89:       - name: Render manifests & run Trivy config scan
90:         run: |
91:           helm template helm/notes-api -f helm/notes-api/values-prod.yaml > rendered.yaml
92: 
93:       - name: Run Trivy config scan
94:         uses: aquasecurity/trivy-action@master
95:         with:
96:           scan-type: 'config'
97:           scan-ref: 'rendered.yaml'
98:           format: 'table'
99:           exit-code: '1'
100:           severity: 'CRITICAL,HIGH'
```

* **Line 80–82 (`azure/setup-helm@v4` with `version: v3.17.1`):**
  * Installs a pinned version of the Helm 3 CLI binary onto the runner.
* **Line 84–87 (`helm dependency build & lint`):**
  * `helm dependency build`: Resolves and downloads the Bitnami PostgreSQL OCI chart into `charts/`.
  * `helm lint`: Evaluates the chart syntax, checks for formatting errors, and validates that values match chart templates.
* **Line 89–92 (`helm template ... > rendered.yaml`):**
  * Evaluates all Go template expressions using production values (`values-prod.yaml`) and compiles them into a single, static multi-document Kubernetes YAML file (`rendered.yaml`).
* **Line 93–101 (`Trivy config scan` with Strict Gate `exit-code: '1'`):**
  * *`scan-type: 'config'`*: Switches Trivy from container OS scanning to **Infrastructure-as-Code (IaC) static analysis**.
  * *`scan-ref: 'rendered.yaml'`*: Evaluates the fully rendered Kubernetes manifests against CIS Kubernetes benchmarks and security policies.
  * *`exit-code: '1'`*: **A real, enforcing security gate.** If an engineer introduces a critical Kubernetes misconfiguration (such as running containers as root, privileged mode, or missing resource limits), the step exits with code 1 and fails the CI run.

---

## 3. Key DevSecOps Principles & Architectural Decisions

### 1. Three Independent Parallel Jobs vs Monolithic Pipeline
* **The Monolithic Approach:** Running Lint -> Docker Build -> Helm Lint sequentially in a single job.
  * *Drawback:* If linting takes 1 minute, and Docker build takes 2 minutes, you wait 3 minutes before finding out your Helm chart had a syntax typo.
* **Our Parallel Approach:** GitHub Actions provisions 3 separate runners simultaneously.
  * *Advantage:* If Helm syntax is invalid, you receive a failure notification within 15 seconds, maximizing developer velocity and providing immediate pinpoint feedback.

### 2. Shift-Left Security: Image Scanning vs IaC Scanning
* **Container Image Scanning:** Checks the inside of the container (compiled binaries, Python libraries, OS packages) for known vulnerabilities (CVEs).
* **IaC Configuration Scanning:** Checks the outside runtime policy (how Kubernetes orchestrates the container). It ensures the container cannot execute with elevated Linux privileges, enforces CPU/memory boundaries, and prevents cluster-level compromise.

---

## 4. Round 3 Interview Defense: Questions & Answers

### Q1: "Why do you tag Docker images with both the Git SHA and `latest`?"
> *"Tagging with the Git commit SHA provides **immutable artifact tracking**. In production, using mutable tags like `latest` is dangerous because you cannot guarantee what code is actually running inside the cluster, and rolling back becomes ambiguous. The SHA tag allows us to trace any running pod directly back to the exact Git commit that produced it. We retain the `latest` tag solely as a convenience pointer for local testing and development."*

### Q2: "Why did you split the pipeline into three parallel jobs instead of one single job?"
> *"Parallelizing jobs optimizes feedback loop speed. If all steps run in one job, a failure in the final Helm step requires waiting for Python linting and Docker building to complete first. By splitting them into `lint`, `docker-build-scan`, and `helm-lint-scan`, GitHub Actions executes all three concurrently. If a developer breaks Helm YAML, the build fails in under 20 seconds, and the failure is isolated to that specific job in the GitHub UI."*

### Q3: "Why did you use `ignore-unfixed: true` in your container vulnerability scan?"
> *"In production DevSecOps, failing builds on vulnerabilities that have no available upstream fix (`unfixed`) creates deployment paralysis. If Debian or Python has an open CVE with no patch, the engineering team cannot resolve it. Setting `ignore-unfixed: true` focuses our blocking security gate strictly on actionable CVEs that have an available vendor patch, preventing pipeline blockages while maintaining high security standards."*

### Q4: "Why did you lowercase the image repository name in your workflow step?"
> *"The Open Container Initiative (OCI) and Docker distribution specifications require all repository and image path names to be strictly lowercase. Since GitHub usernames and repository names often contain uppercase letters, attempting to push an image like `ghcr.io/Gaurravvvv/...` causes Docker to reject the push with an `invalid reference format` error. Lowercasing the string using `tr '[:upper:]' '[:lower:]'` guarantees compatibility."*

### Q5: "What is the difference between Trivy image scan and Trivy config scan?"
> *"The image scan examines the container filesystem and installed package manifests (like `dpkg` and Python wheels) to detect published CVEs from the National Vulnerability Database. The config scan performs static analysis on our rendered Kubernetes YAML manifests to detect infrastructure misconfigurations—such as containers running as root (`runAsNonRoot: false`), missing CPU/memory limits, or privilege escalation."*
