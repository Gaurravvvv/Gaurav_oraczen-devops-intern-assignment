# Task 4 Deep-Dive: GitOps Deployment with ArgoCD

This document provides a line-by-line technical breakdown of the GitOps deployment manifests in `argocd/notes-api-dev.yaml` and `argocd/notes-api-prod.yaml`. It details **what each line means**, **what its work is**, **why we used it**, and **how it works under the hood**, followed by the complete Git-to-cluster rollout lifecycle, troubleshooting playbooks, and likely Round 3 interview questions.

---

## 1. What is GitOps & Why ArgoCD?

**GitOps** is an operational model where:
1. **Git is the Single Source of Truth:** The entire desired state of the infrastructure and application workloads is declared in version-controlled Git repositories.
2. **Pull-Based Deployment:** Instead of a CI pipeline using privileged cluster credentials (`kubectl apply` with cluster-admin secrets inside GitHub Actions), an in-cluster operator (**ArgoCD**) continuously monitors Git and pulls changes inward.
3. **Automated Drift Detection & Reconciliation:** If someone manually modifies or deletes a cluster resource using `kubectl`, ArgoCD detects the divergence between the desired state (Git) and live state (Kubernetes) and automatically reconciles it back to the Git definition.

---

## 2. Line-by-Line Breakdown of `argocd/notes-api-dev.yaml` & `notes-api-prod.yaml`

Below is the complete manifest for the production application (`argocd/notes-api-prod.yaml`):

```yaml
1: apiVersion: argoproj.io/v1alpha1
2: kind: Application
3: metadata:
4:   name: notes-api-prod
5:   namespace: argocd
6:   finalizers:
7:     - resources-finalizer.argocd.argoproj.io
8: spec:
9:   project: default
10:   source:
11:     repoURL: https://github.com/Gaurravvvv/Gaurav_oraczen-devops-intern-assignment.git
12:     targetRevision: main
13:     path: helm/notes-api
14:     helm:
15:       valueFiles:
16:         - values.yaml
17:         - values-prod.yaml
18:   destination:
19:     server: https://kubernetes.default.svc
20:     namespace: notes-prod
21:   syncPolicy:
22:     automated:
23:       prune: false     # Prevent accidental resource deletion in prod
24:       selfHeal: true   # Auto-revert drift back to git state
25:     syncOptions:
26:       - CreateNamespace=true
```

---

### Header & Metadata (Lines 1–7)
* **Line 1 (`apiVersion: argoproj.io/v1alpha1`):** Identifies the API group and version for ArgoCD's Custom Resource Definitions (CRDs).
* **Line 2 (`kind: Application`):** The primary custom resource managed by the ArgoCD Application Controller. It defines the logical connection between a source (Git repo) and a destination (Kubernetes cluster namespace).
* **Line 4 (`name: notes-api-prod`):** Unique name of the Application resource within ArgoCD (`notes-api-dev` for development).
* **Line 5 (`namespace: argocd`):** The namespace where the ArgoCD control plane components (API server, controller, repo-server) reside. All Application CRs must live in this namespace for the controller to process them.
* **Line 6–7 (`finalizers: - resources-finalizer.argocd.argoproj.io`):**
  * *What it means:* Attaches a Kubernetes deletion finalizer managed by ArgoCD.
  * *What its work is:* Controls **cascading deletion**.
  * *Why we used it:* If an operator deletes the ArgoCD Application CR (`kubectl delete application notes-api-dev`), the finalizer instructs ArgoCD to systematically delete all child Kubernetes resources that it created (Deployments, Services, ConfigMaps, Secrets, PVCs).
  * *Without this finalizer:* Deleting the Application CR would leave all deployed workloads orphaned and running in the cluster.

---

### Specification: Source & Helm Values (Lines 8–17)
* **Line 9 (`project: default`):** Assigns this application to the `default` ArgoCD AppProject. Projects provide RBAC boundaries, restricting which Git repositories, cluster destinations, and resource types an Application can manage.
* **Line 10–13 (`source`):**
  * `repoURL: https://github.com/Gaurravvvv/Gaurav_oraczen-devops-intern-assignment.git`: Target Git repository.
  * `targetRevision: main`: The Git branch, tag, or commit SHA tracked by ArgoCD.
  * `path: helm/notes-api`: The subdirectory inside the repo containing the Helm chart.
* **Line 14–17 (`helm.valueFiles`):**
  * Evaluates Helm values sequentially:
    1. `values.yaml` (Base defaults).
    2. `values-prod.yaml` (Environment-specific overrides).
  * *How it works under the hood:* The ArgoCD `repo-server` executes the equivalent of:
    ```bash
    helm template notes-api-prod helm/notes-api -f values.yaml -f values-prod.yaml
    ```
    Values defined in `values-prod.yaml` override any matching keys from `values.yaml`.

---

### Specification: Destination (Lines 18–20)
* **Line 19 (`server: https://kubernetes.default.svc`):** Directs ArgoCD to deploy the application to the **local Kubernetes cluster** where ArgoCD itself is running (the in-cluster API server endpoint).
  * *Note:* If ArgoCD were managing external target clusters (e.g. AWS EKS, Google GKE), this field would hold the external cluster's API endpoint URL.
* **Line 20 (`namespace: notes-prod`):** Isolates workloads into environment-specific namespaces (`notes-dev` vs `notes-prod`).

---

### Specification: Sync Policy & Options (Lines 21–26)

* **Line 22 (`automated`):** Enables automated synchronization without requiring human operators to click "Sync" in the ArgoCD UI.
* **Line 23 (`prune`):**
  * **Dev (`prune: true`):** Automatically deletes cluster resources that were removed from Git. Enables rapid development cleanup.
  * **Prod (`prune: false`):** **Critical safety guardrail.** If a developer accidentally deletes a manifest (such as a database `PersistentVolumeClaim` or TLS Secret) from Git, `prune: false` prevents ArgoCD from automatically destroying the production volume or secrets in the live cluster.
* **Line 24 (`selfHeal: true`):**
  * *What it does:* Prevents manual configuration drift.
  * *How it works:* If an engineer runs `kubectl edit deployment notes-api` or manually scales pods down on the cluster, ArgoCD detects that the live state no longer matches Git and automatically forces the live state back into alignment with Git within seconds.
* **Line 25–26 (`syncOptions: - CreateNamespace=true`):** Instructs ArgoCD to automatically create the target namespace (`notes-dev` or `notes-prod`) if it does not already exist when syncing.

---

## 3. The Complete Rollout Lifecycle: From Git Merge to Running Pod

When a developer changes `image.tag` to `"1.1.0"` in `values-prod.yaml` and merges the pull request to `main`, here is the exact sequence of events:

```text
[ Git Merge to main ]
          │
          ▼
1. ArgoCD Repo-Server polls Git (or receives webhook)
          │
          ▼
2. Helm engine renders manifests (values.yaml + values-prod.yaml)
          │
          ▼
3. Application Controller compares Git AST against etcd live state
          │
          ▼
4. Drift detected: Application state becomes "OutOfSync"
          │
          ▼
5. Controller issues declarative PATCH to Kubernetes Deployment
          │
          ▼
6. Deployment Controller creates new ReplicaSet (hash: xxxxx)
          │
          ▼
7. Kubelet pulls image from GHCR, starts container as UID 1000
          │
          ▼
8. Probes execute: /healthz passes, /readyz validates DB connection
          │
          ▼
9. Pod marked READY (1/1) -> Added to Service Endpoints
          │
          ▼
10. Old ReplicaSet pods terminated -> ArgoCD marks "Synced & Healthy"
```

---

## 4. Troubleshooting Playbook: Where to Look When a Rollout Fails

If an ArgoCD deployment gets stuck, does not roll out, or displays a `Degraded` or `OutOfSync` status, follow this systematic triage process:

### Layer 1: Check ArgoCD Control Plane
```bash
# 1. Inspect the Application status and recent sync events
argocd app get notes-api-prod

# 2. Check ArgoCD Application Controller logs for reconciliation errors
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100
```
* *Common errors:* Git repository unreachable, authentication failure, invalid Helm YAML syntax in values file.

---

### Layer 2: Check Kubernetes Workload & Events
```bash
# 1. Check pod status in the destination namespace
kubectl get pods -n notes-prod

# 2. Inspect cluster events for scheduling or container creation errors
kubectl get events -n notes-prod --sort-by='.metadata.creationTimestamp'
```

---

### Layer 3: Diagnose Specific Pod Failures
```bash
# 1. Describe the failing pod to view lifecycle events
kubectl describe pod <pod-name> -n notes-prod

# 2. View application startup logs
kubectl logs <pod-name> -n notes-prod

# 3. View crash logs if container is crashing on boot
kubectl logs <pod-name> -n notes-prod --previous
```

### Common Failure Modes & Root Causes:
1. **`ImagePullBackOff` / `ErrImagePull`:**
   * *Root Cause:* The image tag in `values-prod.yaml` does not exist in GHCR, the image repository name has uppercase letters, or GHCR credentials are missing.
2. **`CrashLoopBackOff`:**
   * *Root Cause:* The Python application threw an unhandled exception during `on_startup`. Check `kubectl logs --previous` to inspect the traceback.
3. **`Running` but `0/1 Ready` (Readiness Probe Failure):**
   * *Root Cause:* The `/readyz` probe is failing because PostgreSQL is unreachable, the password secret was not resolved, or the database service has not finished booting.
4. **`CreateContainerConfigError`:**
   * *Root Cause:* The deployment references a ConfigMap key or Secret key that does not exist in the namespace.

---

## 5. Round 3 Interview Defense: Questions & Answers

### Q1: "Why did you set `prune: false` in production but `prune: true` in development?"
> *"In development, environments are ephemeral; setting `prune: true` ensures that when manifests are removed from Git, the corresponding cluster resources are immediately purged to keep the cluster clean. In production, `prune: false` acts as a disaster-prevention guardrail. If an engineer accidentally removes a database PersistentVolumeClaim (PVC) or a critical Secret manifest from Git, automated pruning would instantly destroy production storage and data. In production, resource deletions should be deliberate and manually vetted."*

### Q2: "How does `selfHeal: true` handle manual changes made via `kubectl edit`?"
> *"ArgoCD acts as a reconciliation loop between Git and Kubernetes. If someone uses `kubectl edit` or `kubectl scale` to alter a resource on the cluster, ArgoCD’s controller detects the diff between etcd's live state and Git's desired state. With `selfHeal: true`, the controller immediately overwrites the live cluster state with the Git definition, preventing configuration drift and enforcing Git as the absolute authority."*

### Q3: "What is the purpose of `resources-finalizer.argocd.argoproj.io`?"
> *"It enables cascading resource deletion. Without this finalizer, deleting an ArgoCD Application resource would simply delete the metadata object inside ArgoCD, leaving all the child Deployments, Services, and Pods orphaned and running indefinitely on the cluster. The finalizer ensures that deleting the Application cleans up all associated infrastructure components cleanly."*

### Q4: "Walk me through what happens when someone merges a change to `values-prod.yaml`."
> *"ArgoCD detects the new commit either via Git webhook or its background polling loop. Its `repo-server` executes `helm template` using the updated `values-prod.yaml` to compute the new desired manifest tree. The Application Controller compares this against live cluster resources, marks the app `OutOfSync`, and applies a declarative patch. Kubernetes's Deployment controller triggers a rolling update, spinning up a new ReplicaSet. The kubelet pulls the new image and executes the startup and readiness probes (`/readyz`). Once the new pod passes readiness, traffic shifts to it, the old pod is drained and terminated, and ArgoCD reports `Synced & Healthy`."*
