# Task 2 Deep-Dive: Helm Packaging & Database Architecture

This document provides a line-by-line technical breakdown of the Helm chart implementation for the Notes API. It details **what each line means**, **what its work is**, **why we used it**, and **how it works under the hood**, followed by architectural trade-offs and likely Round 3 interview questions.

---

## 1. Line-by-Line Breakdown of `helm/notes-api/Chart.yaml`

`Chart.yaml` is the chart's identity manifest. It declares metadata, the chart API version, and external subchart dependencies.

```yaml
1: apiVersion: v2
2: name: notes-api
3: description: A production-ready Helm chart for FastAPI Notes API with PostgreSQL subchart dependency
4: type: application
5: version: 0.1.0
6: appVersion: "1.0.0"
7: 
8: dependencies:
9:   - name: postgresql
10:     version: "15.5.37"
11:     repository: "oci://registry-1.docker.io/bitnamicharts"
12:     condition: postgresql.enabled
```

* **Line 1 (`apiVersion: v2`):**
  * *What it means:* Specifies that this chart uses Helm 3 schema. (`v1` was used in Helm 2).
  * *What its work is:* Tells the Helm CLI engine how to parse chart dependencies and packaging structures.
  * *Why we used it:* Helm 3 eliminated Tiller (the in-cluster server-side component of Helm 2), improving security by relying directly on the operator's kubeconfig permissions.
* **Line 2 (`name: notes-api`):** The chart identifier used during installation and packaging.
* **Line 3 (`description: ...`):** Human-readable summary displayed in Helm artifact registries.
* **Line 4 (`type: application`):** Declares this is an deployable application chart (as opposed to a `library` chart designed solely to provide reusable template helpers).
* **Line 5 (`version: 0.1.0`):** The semantic version of the **Helm chart itself**. Incremented whenever chart templates or values change.
* **Line 6 (`appVersion: "1.0.0"`):** The version of the **underlying application code** running inside the container.
* **Line 8–12 (`dependencies`):**
  * *Line 9 (`name: postgresql`):* Declares that this chart depends on the PostgreSQL chart.
  * *Line 10 (`version: "15.5.37"`):* Locks the exact subchart version to guarantee reproducible deployments across all environments.
  * *Line 11 (`repository: "oci://registry-1.docker.io/bitnamicharts"`):* Pulls the subchart from Bitnami's official Open Container Initiative (OCI) registry. Modern Helm 3 uses OCI registries instead of legacy HTTP tarball index repositories (`index.yaml`).
  * *Line 12 (`condition: postgresql.enabled`):* Controls whether PostgreSQL is deployed. If `postgresql.enabled` evaluates to `false` (e.g. in environments using an external cloud database like AWS RDS), Helm skips installing the subchart entirely.
* **Under the hood:** When you run `helm dependency build`, Helm queries the OCI registry, downloads the compressed chart archive `postgresql-15.5.37.tgz`, computes its SHA256 checksum, and places it into `helm/notes-api/charts/` alongside a generated `Chart.lock` file.

---

## 2. Environment Configuration Strategy: Base, Dev & Prod Values

We decouple configuration from Kubernetes manifests using a hierarchical values structure:

### Base Defaults (`helm/notes-api/values.yaml`)
Provides sane defaults for local development:
* `replicaCount: 1`
* `image.repository`: `ghcr.io/gaurravvvv/gaurav_oraczen-devops-intern-assignment/notes-api`
* `service.type: ClusterIP`, `service.port: 8000`
* `resources.requests`: CPU 100m, Memory 128Mi; `limits`: CPU 500m, Memory 256Mi
* `probes`: `/healthz` for liveness, `/readyz` for readiness
* `postgresql.enabled: true`, `persistence.enabled: false`

---

### Environment Comparison Matrix: `values-dev.yaml` vs `values-prod.yaml`

| Configuration Key | Dev (`values-dev.yaml`) | Prod (`values-prod.yaml`) | Architectural Rationale |
| :--- | :--- | :--- | :--- |
| **`replicaCount`** | `1` | `3` (or managed by HPA) | Dev minimizes node compute; Prod ensures high availability (HA) across multiple pods. |
| **`image.tag`** | `latest` | `"1.0.0"` | Dev prioritizes fast testing of new builds; Prod requires immutable, pinned releases to prevent unexpected drift. |
| **`image.pullPolicy`** | `Always` | `Always` | Forces the kubelet to verify image digest updates. |
| **`resources.requests`** | `cpu: 50m`, `memory: 64Mi` | `cpu: 250m`, `memory: 256Mi` | Dev accommodates low footprint; Prod guarantees compute reservation on Kubernetes worker nodes. |
| **`resources.limits`** | `cpu: 200m`, `memory: 128Mi` | `cpu: 1000m`, `memory: 512Mi` | Protects the node from container memory leaks (`OOMKilled` boundary). |
| **`postgresql.primary.persistence`** | `enabled: false` (ephemeral) | `enabled: true`, `size: 10Gi` | Dev uses in-memory/ephemeral storage for rapid tear-down; Prod provisions a persistent volume (`PVC`) to protect user data across pod restarts. |
| **`autoscaling.enabled`** | `false` | `true` (`min: 3, max: 10, target: 75%`) | Dev maintains constant state; Prod elastically scales up during high HTTP traffic surges. |

---

## 3. Line-by-Line Breakdown of `templates/deployment.yaml`

`deployment.yaml` is the core workload manifest that instructs Kubernetes how to create, update, and monitor the FastAPI container.

```yaml
1: apiVersion: apps/v1
2: kind: Deployment
3: metadata:
4:   name: {{ .Release.Name }}-notes-api
5:   labels:
6:     app: notes-api
7:     release: {{ .Release.Name }}
8: spec:
9:   {{- if not .Values.autoscaling.enabled }}
10:   replicas: {{ .Values.replicaCount }}
11:   {{- end }}
12:   selector:
13:     matchLabels:
14:       app: notes-api
15:       release: {{ .Release.Name }}
16:   template:
17:     metadata:
18:       labels:
19:         app: notes-api
20:         release: {{ .Release.Name }}
21:     spec:
22:       serviceAccountName: {{ .Release.Name }}-notes-api
23:       securityContext:
24:         runAsNonRoot: true
25:         runAsUser: 1000
26:       containers:
27:         - name: notes-api
28:           image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
29:           imagePullPolicy: {{ .Values.image.pullPolicy }}
30:           securityContext:
31:             readOnlyRootFilesystem: true
32:             allowPrivilegeEscalation: false
33:             capabilities:
34:               drop:
35:                 - ALL
36:           volumeMounts:
37:             - name: tmp
38:               mountPath: /tmp
39:           ports:
40:             - containerPort: {{ .Values.service.port }}
41:           envFrom:
42:             - configMapRef:
43:                 name: {{ .Release.Name }}-notes-api-config
44:           env:
45:             - name: POSTGRES_PASSWORD
46:               valueFrom:
47:                 secretKeyRef:
48:                   name: {{ .Release.Name }}-postgresql
49:                   key: password
50:           resources:
51:             {{- toYaml .Values.resources | nindent 12 }}
52:           livenessProbe:
53:             httpGet:
54:               path: {{ .Values.probes.liveness.path }}
55:               port: {{ .Values.service.port }}
56:             initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
57:             periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
58:           readinessProbe:
59:             httpGet:
60:               path: {{ .Values.probes.readiness.path }}
61:               port: {{ .Values.service.port }}
62:             initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
63:             periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
64:       volumes:
65:         - name: tmp
66:           emptyDir: {}
```

### Detailed Lines Breakdown:

* **Line 4 (`name: {{ .Release.Name }}-notes-api`):** Prefixes the deployment name with the Helm release name (e.g. `notes-api-dev-notes-api`). This prevents resource collisions when deploying multiple releases into the same Kubernetes cluster.
* **Line 9–11 (`{{- if not .Values.autoscaling.enabled }}`):**
  * *Why this is critical:* When Horizontal Pod Autoscaling (HPA) is enabled, the HPA controller dynamically adjusts `spec.replicas`. If the Deployment manifest explicitly sets `replicas: 3`, every time ArgoCD or Helm syncs, it would fight with the HPA, constantly resetting the replica count back to 3 and creating a scaling loop. Omitting `replicas` when HPA is active cedes replica management to the autoscaler.
* **Line 12–15 (`selector.matchLabels`):** Defines the label selector the Kubernetes Deployment controller uses to find and manage its ReplicaSet and Pods.
* **Line 22 (`serviceAccountName: {{ .Release.Name }}-notes-api`):** Binds the pod to a dedicated ServiceAccount rather than `default`. Limits the pod's API server privileges.
* **Line 23–25 (`pod.spec.securityContext`):**
  * `runAsNonRoot: true`: Forces the kubelet container runtime to validate that the image's entrypoint user is not UID 0. If an image attempts to run as root, the kubelet halts pod startup with a `CreateContainerConfigError`.
  * `runAsUser: 1000`: Matches the unprivileged user created in our Dockerfile (`appuser`).
* **Line 30–35 (`container.securityContext` - Trivy KSV-0014 Remediation):**
  * `readOnlyRootFilesystem: true`: Makes the container root filesystem immutable. Attackers cannot tamper with files or inject malware binaries.
  * `allowPrivilegeEscalation: false`: Prevents child processes from gaining more privileges than their parent process.
  * `capabilities.drop: [ALL]`: Drops all default Linux kernel capabilities.
* **Line 36–38 & 64–66 (`volumeMounts` & `volumes.emptyDir`):**
  * Mounts a writable scratchpad at `/tmp` so Python/Uvicorn can write temporary files without violating `readOnlyRootFilesystem`.
* **Line 28 (`image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"`):** Dynamically stitches together the registry, repo name, and version tag.
* **Line 32–34 (`envFrom.configMapRef`):** Injects non-sensitive environment variables (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`) in bulk from the ConfigMap.
* **Line 35–40 (`env.POSTGRES_PASSWORD` with `secretKeyRef`):**
  * *What it does:* Securely retrieves the database password from the Kubernetes Secret generated automatically by the Bitnami PostgreSQL subchart.
  * *How it works:* The Bitnami chart creates a Secret named `<release-name>-postgresql` containing a base64-encoded key called `password`. Our application reads it into the `POSTGRES_PASSWORD` environment variable without ever committing secrets to Git.
* **Line 41–42 (`resources: {{- toYaml .Values.resources | nindent 12 }}`):**
  * Renders CPU and memory requests/limits.
  * `nindent 12`: Indents the rendered YAML block by 12 spaces, maintaining strict YAML indentation rules.
* **Line 43–48 (`livenessProbe`):**
  * Periodically sends an HTTP GET request to `/healthz` on port 8000 every 10 seconds.
  * *Purpose:* Detects process deadlocks or fatal hangs. If this probe fails 3 consecutive times, kubelet restarts the container.
* **Line 49–54 (`readinessProbe`):**
  * Periodically sends an HTTP GET request to `/readyz` every 10 seconds.
  * *Purpose:* Checks whether the application can successfully query the PostgreSQL database (`SELECT 1`). If the database is still booting or down, `/readyz` returns HTTP 503, and Kubernetes temporarily removes the pod IP from the Service endpoints so no live traffic is routed to an unready pod.

---

## 4. Line-by-Line Breakdown of Supporting Templates

### `templates/service.yaml`
```yaml
1: apiVersion: v1
2: kind: Service
3: metadata:
4:   name: {{ .Release.Name }}-notes-api
5:   labels:
6:     app: notes-api
7:     release: {{ .Release.Name }}
8: spec:
9:   type: {{ .Values.service.type }}
10:   ports:
11:     - port: {{ .Values.service.port }}
12:       targetPort: {{ .Values.service.port }}
13:       protocol: TCP
14:       name: http
15:   selector:
16:     app: notes-api
17:     release: {{ .Release.Name }}
```
* **Line 9 (`type: ClusterIP`):** Exposes the service on an internal IP address reachable only within the Kubernetes cluster.
* **Line 11–12 (`port` & `targetPort`):** Routes traffic incoming on port 8000 to port 8000 of the pods matching `selector` (`app: notes-api`).
* **Under the hood:** Kube-proxy programmatically provisions iptables/IPVS rules across all worker nodes to load-balance requests across all ready pod IPs.

---

### `templates/configmap.yaml`
```yaml
1: apiVersion: v1
2: kind: ConfigMap
3: metadata:
4:   name: {{ .Release.Name }}-notes-api-config
5:   labels:
6:     app: notes-api
7:     release: {{ .Release.Name }}
8: data:
9:   POSTGRES_HOST: "{{ .Release.Name }}-postgresql"
10:   POSTGRES_PORT: {{ .Values.config.postgresPort | default "5432" | quote }}
11:   POSTGRES_DB: {{ .Values.postgresql.auth.database | default "notes" | quote }}
12:   POSTGRES_USER: {{ .Values.postgresql.auth.username | default "notes" | quote }}
```
* **Line 9 (`POSTGRES_HOST: "{{ .Release.Name }}-postgresql"`):** Kubernetes ClusterIP DNS discovery. The Bitnami PostgreSQL subchart creates a Service named `<release>-postgresql`. Pods resolve this hostname automatically through CoreDNS.
* **Line 10–12 (`| default ... | quote`):** Go template pipelines. If a value is missing in `values.yaml`, it falls back to default (`"notes"`, `"5432"`), and the `quote` function surrounds the result with quotation marks to ensure valid YAML string types.

---

### `templates/serviceaccount.yaml`
```yaml
1: apiVersion: v1
2: kind: ServiceAccount
3: metadata:
4:   name: {{ .Release.Name }}-notes-api
5:   labels:
6:     app: notes-api
7:     release: {{ .Release.Name }}
```
* Creates a dedicated identity for the Notes API pods. If RBAC policies are applied in the future, permissions can be granted specifically to this ServiceAccount without exposing the cluster to other workloads.

---

### `templates/hpa.yaml`
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
* **Line 1 & 23 (`{{- if ... }} ... {{- end }}`):** Conditional wrapper. When `autoscaling.enabled` is `false` (Dev), this file renders into 0 bytes and Kubernetes creates no HPA resource.
* **Line 10–13 (`scaleTargetRef`):** Points the autoscaler directly at our Deployment.
* **Line 16–22 (`metrics`):** Queries the Kubernetes Metrics Server. When average CPU consumption across pods exceeds 75% of requested CPU, the HPA controller calculates `desiredReplicas = ceil[currentReplicas * (currentMetricValue / desiredMetricValue)]` and scales up to 10 pods.

---

## 5. Key Architectural Decisions & Engineering Rationale

### 1. Subchart Dependency vs Standalone PostgreSQL Manifests
* **The Naive Way:** Writing custom `Deployment`, `StatefulSet`, and `Service` YAML for PostgreSQL directly in the chart.
* **Our Production Approach:** Using the official Bitnami subchart (`oci://registry-1.docker.io/bitnamicharts/postgresql`). Bitnami's chart is industry-standard, continuously vetted for security, supports replication, handles automated Secret generation, and implements volume permission fixing (`initContainers`).

### 2. Strict Probe Separation: Liveness vs Readiness
* **Liveness (`/healthz`):** Only checks if the Python/Uvicorn process is responsive. **It deliberately does NOT connect to PostgreSQL.**
  * *Why:* If PostgreSQL temporarily restarts or experiences a network blip, a liveness probe checking the database would fail, causing Kubernetes to restart the API pod. Restarting the API pod does not fix the database and creates cascading failure loops across the cluster.
* **Readiness (`/readyz`):** Executes `SELECT 1` on PostgreSQL.
  * *Why:* If PostgreSQL is down, the API cannot serve user traffic. Readiness probe failure unregisters the pod from the Service endpoints without killing the process, preserving connections and logs until the database recovers.

---

## 6. Round 3 Interview Defense: Questions & Answers

### Q1: "How does the Notes API pod retrieve the PostgreSQL password without storing it in plain text?"
> *"We use Kubernetes `secretKeyRef` in `deployment.yaml`. The Bitnami PostgreSQL subchart dynamically generates a Kubernetes Secret named `<release-name>-postgresql` with a base64-encoded `password` key. Our deployment references this secret directly:
> ```yaml
> env:
>   - name: POSTGRES_PASSWORD
>     valueFrom:
>       secretKeyRef:
>         name: {{ .Release.Name }}-postgresql
>         key: password
> ```
> This completely decouples secret storage from application code and Helm values, ensuring zero credentials are committed to version control."*

### Q2: "Why did you wrap `replicas` in an `if not .Values.autoscaling.enabled` check in `deployment.yaml`?"
> *"If a Deployment declares `replicas: 3` while an HPA is active, the Kubernetes Deployment controller and the HPA controller enter a race condition. When traffic increases, the HPA scales the deployment to 6. If Helm or ArgoCD syncs, the manifest re-applies `replicas: 3`, instantly resetting the scale. Omitting the `replicas` field when autoscaling is enabled allows the HPA to maintain full authority over pod counts."*

### Q3: "What happens if PostgreSQL crashes? How do your probes react?"
> *"Because our liveness probe (`/healthz`) does not touch PostgreSQL, the API pod will remain alive and avoid unnecessary restart loops. Meanwhile, the readiness probe (`/readyz`), which executes `SELECT 1`, will fail and return HTTP 503. Kubernetes will immediately mark the pod as unready and remove its IP from the Service endpoints, preventing end users from receiving 500 errors until PostgreSQL recovers."*

### Q4: "Explain the difference between Go template syntax `{{` and `{{-`."
> *"In Go templating, `{{` retains whitespace and newlines around the evaluated block. The hyphen (`{{-` or `-}}`) trims leading or trailing whitespace and newlines. This is critical in Kubernetes YAML where indentation defines object hierarchy. We use `{{- toYaml .Values.resources | nindent 12 }}` to ensure the rendered resources block aligns perfectly with 12 spaces."*
