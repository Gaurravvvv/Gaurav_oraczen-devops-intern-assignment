# Task 5 Deep-Dive: Stretch Goals, Autoscaling & Master Interview Defense

This document details the advanced stretch goals implemented in this assignment (Horizontal Pod Autoscaling, production storage persistence, and zero-downtime rolling updates), followed by the **Ultimate Round 3 Technical Interview Master Defense Cheatsheet**.

---

## 1. Stretch Goals Overview & Architecture

We implemented four key production stretch enhancements:

1. **Horizontal Pod Autoscaling (HPA v2):** Dynamic replica scaling (3 to 10 pods) based on real-time CPU metric thresholds.
2. **PostgreSQL Persistent Storage:** Dynamic `PersistentVolumeClaim` (PVC) provisioning (10Gi) in production to safeguard database state across pod crashes and restarts.
3. **Zero-Downtime Rolling Updates:** Coupling Kubernetes Deployment rollout strategies with readiness probe validation to achieve zero dropped requests during new releases.
4. **Active Vulnerability Remediation (CVE-2024-xxxx):** Upgrading `fastapi>=0.115.6` to eliminate upstream Starlette multipart parsing vulnerabilities.

---

## 2. Line-by-Line Breakdown of `templates/hpa.yaml`

```yaml
1: {{- if .Values.autoscaling.enabled }}
2: apiVersion: autoscaling/v2
3: kind: HorizontalPodAutoscaler
4: metadata:
5:   name: {{ .Release.Name }}-notes-api
6:   labels:
7:     app: notes-api
8:     release: {{ .Release.Name }}
9: spec:
10:   scaleTargetRef:
11:     apiVersion: apps/v1
12:     kind: Deployment
13:     name: {{ .Release.Name }}-notes-api
14:   minReplicas: {{ .Values.autoscaling.minReplicas }}
15:   maxReplicas: {{ .Values.autoscaling.maxReplicas }}
16:   metrics:
17:     - type: Resource
18:       resource:
19:         name: cpu
20:         target:
21:           type: Utilization
22:           averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
23: {{- end }}
```

* **Line 1 & 23 (`{{- if .Values.autoscaling.enabled }}` ... `{{- end }}`):**
  * *What it means:* Controls whether the HPA manifest is rendered.
  * *How it works:* In Dev (`autoscaling.enabled: false`), the template evaluates to empty whitespace, preventing unnecessary HPA controller overhead on small test clusters. In Prod (`autoscaling.enabled: true`), the HPA resource is created.
* **Line 2 (`apiVersion: autoscaling/v2`):**
  * *Why `v2` over `v1`:* `autoscaling/v1` only supported integer CPU thresholds. `autoscaling/v2` supports multiple metrics simultaneously (Memory, Custom metrics like HTTP requests/second from Prometheus, and external cloud metrics), as well as configurable scale-up and scale-down stabilization windows.
* **Line 9–13 (`scaleTargetRef`):**
  * Directs the Kubernetes HPA controller to monitor and adjust our specific Deployment (`{{ .Release.Name }}-notes-api`).
* **Line 14–15 (`minReplicas` & `maxReplicas`):**
  * Sets the operational boundaries:
    * `minReplicas: 3`: Ensures high availability across multiple failure zones/nodes even during low-traffic periods.
    * `maxReplicas: 10`: Places an upper ceiling to prevent runaway pod scaling from consuming all cluster worker node memory and CPU.
* **Line 16–22 (`metrics.target.averageUtilization: 75`):**
  * *The Autoscaling Formula:*
    $$\text{desiredReplicas} = \left\lceil \text{currentReplicas} \times \left( \frac{\text{currentMetricValue}}{\text{desiredMetricValue}} \right) \right\rceil$$
  * *How it works under the hood:* The HPA controller queries the `metrics.k8s.io` API every 15 seconds. If the 3 pods have a requested CPU of 250m each (total 750m) and average usage spikes to 375m (150% of request, well above the 75% target), the HPA controller calculates:
    $$\text{desiredReplicas} = \left\lceil 3 \times \left( \frac{150\%}{75\%} \right) \right\rceil = 6 \text{ pods}$$
    It then patches `spec.replicas` on the Deployment to 6.

---

## 3. Production Storage Persistence: Dev vs Prod

### Why Ephemeral in Dev (`persistence.enabled: false`)
In local development and CI testing, we want disposable environments. When the dev namespace or Kind cluster is destroyed, all database volumes are wiped instantly without leaving orphaned virtual disks or PVC locks.

### Why PersistentVolumeClaims in Prod (`persistence.enabled: true`, `10Gi`)
In production, database data must survive pod crashes, node maintenance, and cluster upgrades:
* The Bitnami PostgreSQL subchart creates a `PersistentVolumeClaim` (PVC) bound to a Kubernetes `StorageClass`.
* When a PostgreSQL pod crashes or is rescheduled onto a different worker node, the storage driver detaches the virtual disk from the failed node and mounts it to the new node at `/bitnami/postgresql/data`.
* The database engine starts up, replays write-ahead logs (WAL), and resumes with zero data loss.

---

## 4. Zero-Downtime Rolling Update Mechanics

When a new container version (`1.1.0`) is deployed, Kubernetes executes a **Rolling Update**:

```text
Step 1: Deployment creates new ReplicaSet (RS-v2) with replica count 1.
Step 2: Kubelet boots Pod-v2.
Step 3: Pod-v2 runs /healthz (process is up).
Step 4: Pod-v2 runs /readyz (validates DB connection).
Step 5: Pod-v2 becomes READY (1/1) -> Added to Service Endpoints.
Step 6: Deployment scales old ReplicaSet (RS-v1) down by 1 pod.
Step 7: Pod-v1 receives SIGTERM -> drains active HTTP connections -> terminates.
Step 8: Process repeats until all pods are running v2.
```

* **Why Readiness Probes are Critical for Zero Downtime:** Without a readiness probe, Kubernetes adds the new pod to the Service endpoint immediately upon container startup—before the Python interpreter has imported libraries or connected to PostgreSQL. Incoming user traffic routed to the booting container immediately returns HTTP 502/503 errors. The readiness probe blocks traffic until the app is fully initialized.

---

## 5. Round 3 Master Defense: Top 12 Interview Questions & Answers

### Q1: "Explain the difference between Docker `CMD` and `ENTRYPOINT`."
> *" `ENTRYPOINT` specifies the core binary that should always run when the container starts (e.g. `["uvicorn"]`). `CMD` defines the default arguments passed to that entrypoint (e.g. `["main:app", "--host", "0.0.0.0"]`). When using `CMD` alone in exec format, the first element is the executable. The primary operational difference is that `CMD` arguments can be easily overridden from the command line (`docker run <image> python test.py`), whereas overriding an `ENTRYPOINT` requires explicitly using the `--entrypoint` flag."*

### Q2: "Why didn't you use Docker Compose instead of Kind, Helm, and ArgoCD?"
> *"Docker Compose is designed for single-host development, but it lacks enterprise orchestration capabilities: it does not support declarative GitOps reconciliation, self-healing, rolling zero-downtime updates, horizontal pod autoscaling, or RBAC security policies. Using Kind simulates a true multi-node Kubernetes production topology locally, while Helm and ArgoCD provide production-grade packaging and automated continuous delivery."*

### Q3: "How does the Notes API find PostgreSQL inside the cluster?"
> *"Through Kubernetes internal DNS (CoreDNS). The Bitnami PostgreSQL subchart provisions a `ClusterIP` Service named `<release-name>-postgresql`. Inside our ConfigMap, we inject `POSTGRES_HOST: <release-name>-postgresql`. CoreDNS automatically resolves this service hostname to the cluster virtual IP of the database, load-balancing traffic to the healthy PostgreSQL pod on port 5432."*

### Q4: "What happens if a pod runs out of memory (`OOMKilled`) vs CPU throttling?"
> *"CPU is a **compressible resource**. If a container exceeds its CPU limit (`500m`), the Linux kernel's Completely Fair Scheduler (CFS) throttles the container's CPU shares. The application slows down, but it does not terminate. Memory is an **incompressible resource**. If a container exceeds its memory limit (`256Mi`), the Linux kernel Out-Of-Memory Killer immediately sends a `SIGKILL` (signal 9) to the process. Kubernetes reports the pod termination as `OOMKilled` (Exit Code 137) and restarts it according to the pod restart policy."*

### Q5: "Why use `secretKeyRef` instead of putting database passwords in Helm values?"
> *"Helm values files (`values.yaml`, `values-prod.yaml`) are committed to version-controlled Git repositories. Hardcoding passwords in Git is a critical security vulnerability that violates credential hygiene and compliance standards. Using `secretKeyRef` decouples secret storage: the Bitnami chart generates the secret securely in-cluster, and our deployment references it at runtime without any human or Git repository ever handling plain-text credentials."*

### Q6: "How does ArgoCD detect drift without constantly polling GitHub every second?"
> *"ArgoCD uses two complementary mechanisms:
> 1. **Webhook Integration:** GitHub can be configured with an ArgoCD webhook endpoint. Whenever a PR merges to `main`, GitHub sends a push payload, triggering an immediate sync within 1 second.
> 2. **Polling Loop:** In the absence of a webhook, ArgoCD runs a default reconciliation loop (typically every 3 minutes) where the `repo-server` polls the remote Git repository to detect any un-synced commits."*

### Q7: "Why did you use `python:3.12-slim` instead of Alpine Linux?"
> *"Alpine Linux is built on `musl libc`, whereas official Python wheels for complex C-extension packages like `psycopg2-binary` and `uvicorn[standard]` are pre-compiled for GNU C Library (`glibc` via `manylinux`). On Alpine, pip cannot use pre-built wheels and must compile everything from source during `docker build`, requiring compilers (`gcc`, `make`, `g++`) that dramatically slow build times and increase final image size. Debian Slim provides `glibc` out of the box with zero compilation overhead."*

### Q8: "What would happen if your readiness probe was misconfigured or tested the wrong endpoint?"
> *"If a readiness probe fails continuously (e.g. testing an invalid path or failing database query), Kubernetes will **never** mark the pod as `Ready (1/1)`. As a result, the pod's IP address will never be added to the Kubernetes Service endpoints. If this happens during a rolling update, Kubernetes detects that the new pod cannot become ready, halts the deployment, and leaves the old ReplicaSet running, preventing an outage."*

### Q9: "Why is `runAsNonRoot: true` in `deployment.yaml` important when you already have `USER appuser` in `Dockerfile`?"
> *"This is the **defense-in-depth** principle. The Dockerfile's `USER appuser` is an image-level configuration that could be bypassed or overwritten by an engineer specifying `--user 0` or altering the base image. The Kubernetes `securityContext: runAsNonRoot: true` is an **infrastructure-level enforcement gate**. The kubelet validates the container runtime before starting the container; if the image attempts to run as UID 0, Kubernetes rejects the pod with `CreateContainerConfigError`."*

### Q10: "Explain your CI pipeline's Trivy security gates."
> *"We enforce two independent blocking security gates:
> 1. **Container Image Scan:** Scans the built image filesystem for known CVEs. With `exit-code: 1` and `severity: CRITICAL,HIGH`, any unpatched severe vulnerability immediately fails the build, preventing the image from being pushed to GHCR. We pair this with `ignore-unfixed: true` to prevent blocking builds on upstream Linux vulnerabilities that do not yet have a patch.
> 2. **IaC Configuration Scan:** Scans our rendered Kubernetes YAML with `trivy config` and `exit-code: 1` to block infrastructure anti-patterns (such as root containers, privilege escalation, or missing limits) before manifests are deployed."*

### Q11: "What is the difference between `requests` and `limits` in Kubernetes?"
> *" `requests` are used by the Kubernetes **kube-scheduler** for placement decisions. A pod will only be scheduled onto a worker node that has sufficient unallocated CPU and memory to satisfy the request. `limits` are enforced by the node's **kubelet and Linux cgroups**. They represent the absolute maximum resources a container can consume. CPU limits result in throttling; memory limits result in an `OOMKilled` termination if exceeded."*

### Q12: "If an interviewer asks you to debug live in the interview, what are your first three commands?"
> 1. `kubectl get pods -n <namespace> -o wide` (Checks pod status, restarts, node placement, and readiness).
> 2. `kubectl describe pod <pod-name> -n <namespace>` (Inspects pod lifecycle events, probe failures, scheduling errors, and image pull statuses).
> 3. `kubectl logs <pod-name> -n <namespace> --previous` (Reads application stdout/stderr logs from the previous container instance if the pod is crash-looping)."*

---

## 6. Live Debugging Cheatsheet (Quick Reference)

### Kubernetes Workload Debugging
```bash
# Check all pods across all namespaces
kubectl get pods -A

# Check pod events sorted chronologically
kubectl get events -n notes-prod --sort-by='.metadata.creationTimestamp'

# Describe failing pod
kubectl describe pod <pod-name> -n notes-prod

# Stream container logs
kubectl logs -f <pod-name> -n notes-prod

# Inspect crash logs from previous crash
kubectl logs <pod-name> -n notes-prod --previous

# Exec into container for live inspection
kubectl exec -it <pod-name> -n notes-prod -- /bin/sh
```

### Helm Operations
```bash
# Lint chart syntax
helm lint helm/notes-api

# Render manifests locally
helm template notes-api helm/notes-api -f helm/notes-api/values-prod.yaml

# Check installed Helm releases
helm list -A
```

### ArgoCD Commands
```bash
# Check application sync and health status
argocd app get notes-api-prod

# Manually trigger hard refresh from Git
argocd app sync notes-api-prod --force

# View ArgoCD application controller logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50
```
