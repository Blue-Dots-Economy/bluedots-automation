# Signals Search — Plan 4: Deploy (automation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. This plan is **infrastructure (Helm/OpenTofu)** — tasks verify with `helm lint` / `helm template` assertions instead of unit tests.

**Goal:** Deploy `signals-search` (ingestion worker + query API) and a CPU **TEI** service (BGE-M3 embeddings + bge-reranker-v2-m3, co-located in one pod) into the `signals` namespace, and enable `pgvector` + `postgis` on the shared Postgres for both the self-hosted and RDS/Aurora paths.

**Architecture:** Both new services are **subcharts of the existing `signals` umbrella** (`helm/signals/charts/`), so they deploy with the existing `deploy_signals` step — no new `install.sh` function. Extensions are added to the `common-services` Postgres bootstrap (self-hosted) and to the api `migrate-job` admin branch (RDS/Aurora, where there is no initdb hook). The search service reaches embeddings/rerank in-cluster at `http://signals-search-embeddings`.

**Tech Stack:** Helm 3, Bitnami Postgres/Redis (common-services), HuggingFace TEI image, OpenTofu output-file values. Mirrors existing `helm/signals/charts/api` (API) and `helm/aggregator/charts/worker` (worker) patterns.

**Master tracker:** Blue-Dots-Economy/Signals-DPG#171 · **This repo:** Blue-Dots-Economy/bluedots-automation#22 · **Spec:** https://github.com/Blue-Dots-Economy/signals-search/blob/feat/search-engine-v1/docs/2026-06-09-signals-search-engine-design.md

**Prerequisites / cross-plan:** the `item_search` DDL + extensions land in Signals-DPG `schema.sql` (Plan 3 Task 1), applied by the existing api `migrate-job`. The search service images (`signals-search/worker`, `signals-search/api`) are produced by signals-search CI (Plans 1–2). Confirm **RDS vs Aurora** + pin an engine with pgvector ≥0.7 + PostGIS (tracked in #22).

---

### Task 1: Enable `vector` + `postgis` (self-hosted bootstrap + RDS migrate path)

**Files:**
- Modify: `helm/common-services/values.yaml` (postgres `initdb.scripts.00-bootstrap.sh`)
- Modify: `helm/signals/charts/api/templates/migrate-job.yaml` (the admin `CREATE EXTENSION` line)

- [ ] **Step 1: Self-hosted bootstrap** — in `helm/common-services/values.yaml`, extend the `psql ... -d dpg` heredoc in `00-bootstrap.sh` to:

```bash
          psql -v ON_ERROR_STOP=1 --username postgres -d dpg <<-SQL
            CREATE EXTENSION IF NOT EXISTS pgcrypto;
            CREATE EXTENSION IF NOT EXISTS cube;
            CREATE EXTENSION IF NOT EXISTS earthdistance;
            CREATE EXTENSION IF NOT EXISTS vector;
            CREATE EXTENSION IF NOT EXISTS postgis;
          SQL
```

- [ ] **Step 2: RDS/Aurora path** — in `helm/signals/charts/api/templates/migrate-job.yaml`, the admin-creds branch runs `CREATE EXTENSION ...` as the admin/`rds_superuser`. Extend that `-c` statement to include the two new extensions:

```bash
                  -c "CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS cube; CREATE EXTENSION IF NOT EXISTS earthdistance; CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS postgis;"
```

> On RDS/Aurora, `vector` and `postgis` must also be allowlisted in the instance **parameter group** (`rds.allowed_extensions` if restricted) and the engine version must ship pgvector ≥0.7 — a console/Terraform step tracked in #22, not a Helm change.

- [ ] **Step 3: Verify the bootstrap renders with the new extensions**

Run: `helm template common-services helm/common-services | grep -E "CREATE EXTENSION IF NOT EXISTS (vector|postgis)" | wc -l`
Expected: `2`.

- [ ] **Step 4: Verify the migrate-job renders with the new extensions** (admin branch present)

Run: `helm template signals helm/signals 2>/dev/null | grep -c "CREATE EXTENSION IF NOT EXISTS vector"`
Expected: ≥ `1`.

- [ ] **Step 5: Commit**

```bash
git add helm/common-services/values.yaml helm/signals/charts/api/templates/migrate-job.yaml
git commit -m "feat: enable pgvector + postgis (bootstrap + RDS migrate path)"
```

---

### Task 2: `search-embeddings` subchart (TEI — embeddings + reranker, one pod, CPU)

**Files:**
- Create: `helm/signals/charts/search-embeddings/Chart.yaml`
- Create: `helm/signals/charts/search-embeddings/values.yaml`
- Create: `helm/signals/charts/search-embeddings/templates/_helpers.tpl`
- Create: `helm/signals/charts/search-embeddings/templates/deployment.yaml`
- Create: `helm/signals/charts/search-embeddings/templates/service.yaml`

- [ ] **Step 1: `Chart.yaml`**

```yaml
apiVersion: v2
name: dpg-search-embeddings
description: HuggingFace TEI serving BGE-M3 (embeddings) + bge-reranker-v2-m3 (rerank), co-located CPU pod
type: application
version: 0.1.0
appVersion: "1.0.0"
```

- [ ] **Step 2: `values.yaml`**

```yaml
replicaCount: 1
image:
  repository: ghcr.io/huggingface/text-embeddings-inference
  tag: "cpu-1.7"
  pullPolicy: IfNotPresent
imagePullSecrets: []
embeddings:
  modelId: BAAI/bge-m3
  port: 80
reranker:
  enabled: true
  modelId: BAAI/bge-reranker-v2-m3
  port: 8081
resources:
  requests: { cpu: "1", memory: 2Gi }
  limits:   { cpu: "2", memory: 4Gi }
serviceAccount:
  create: true
```

- [ ] **Step 3: `templates/_helpers.tpl`**

```yaml
{{- define "search-embeddings.name" -}}search-embeddings{{- end -}}
{{- define "search-embeddings.fullname" -}}{{ .Release.Name }}-search-embeddings{{- end -}}
{{- define "search-embeddings.labels" -}}
app.kubernetes.io/name: {{ include "search-embeddings.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "search-embeddings.selectorLabels" -}}
app.kubernetes.io/name: {{ include "search-embeddings.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "search-embeddings.serviceAccountName" -}}{{ include "search-embeddings.fullname" . }}{{- end -}}
```

- [ ] **Step 4: `templates/deployment.yaml`** (two TEI containers in one pod; ServiceAccount inline)

```yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "search-embeddings.serviceAccountName" . }}
  labels: {{- include "search-embeddings.labels" . | nindent 4 }}
---
{{- end }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "search-embeddings.fullname" . }}
  labels: {{- include "search-embeddings.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels: {{- include "search-embeddings.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels: {{- include "search-embeddings.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "search-embeddings.serviceAccountName" . }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets: {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: tei-embeddings
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args: ["--model-id", "{{ .Values.embeddings.modelId }}", "--port", "{{ .Values.embeddings.port }}"]
          ports:
            - name: embed
              containerPort: {{ .Values.embeddings.port }}
          readinessProbe:
            httpGet: { path: /health, port: embed }
            initialDelaySeconds: 20
            periodSeconds: 10
          resources: {{- toYaml .Values.resources | nindent 12 }}
        {{- if .Values.reranker.enabled }}
        - name: tei-reranker
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args: ["--model-id", "{{ .Values.reranker.modelId }}", "--port", "{{ .Values.reranker.port }}"]
          ports:
            - name: rerank
              containerPort: {{ .Values.reranker.port }}
          readinessProbe:
            httpGet: { path: /health, port: rerank }
            initialDelaySeconds: 20
            periodSeconds: 10
          resources: {{- toYaml .Values.resources | nindent 12 }}
        {{- end }}
```

- [ ] **Step 5: `templates/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "search-embeddings.fullname" . }}
  labels: {{- include "search-embeddings.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  selector: {{- include "search-embeddings.selectorLabels" . | nindent 4 }}
  ports:
    - name: embed
      port: {{ .Values.embeddings.port }}
      targetPort: embed
    {{- if .Values.reranker.enabled }}
    - name: rerank
      port: {{ .Values.reranker.port }}
      targetPort: rerank
    {{- end }}
```

- [ ] **Step 6: Verify it lints + renders** (after wiring the dep in Task 4)

Run: `helm lint helm/signals/charts/search-embeddings`
Expected: "1 chart(s) linted, 0 chart(s) failed".

- [ ] **Step 7: Commit**

```bash
git add helm/signals/charts/search-embeddings
git commit -m "feat: search-embeddings subchart (TEI BGE-M3 + reranker, CPU, one pod)"
```

---

### Task 3: `search` subchart (ingestion worker + query API)

**Files:**
- Create: `helm/signals/charts/search/Chart.yaml`
- Create: `helm/signals/charts/search/values.yaml`
- Create: `helm/signals/charts/search/templates/_helpers.tpl`
- Create: `helm/signals/charts/search/templates/secret.yaml`
- Create: `helm/signals/charts/search/templates/configmap.yaml`
- Create: `helm/signals/charts/search/templates/deployment-worker.yaml`
- Create: `helm/signals/charts/search/templates/deployment-api.yaml`
- Create: `helm/signals/charts/search/templates/service.yaml`

- [ ] **Step 1: `Chart.yaml`**

```yaml
apiVersion: v2
name: dpg-search
description: Signals search engine — ingestion worker + query API (pgvector + PostGIS)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

- [ ] **Step 2: `values.yaml`**

```yaml
workerImage:
  repository: ghcr.io/blue-dots-economy/signals-search/worker
  tag: "develop"
  pullPolicy: Always
apiImage:
  repository: ghcr.io/blue-dots-economy/signals-search/api
  tag: "develop"
  pullPolicy: Always
imagePullSecrets:
  - name: ghcr-pull
worker:
  replicaCount: 1
  resources: { requests: { cpu: 100m, memory: 384Mi }, limits: { cpu: 1, memory: 1Gi } }
api:
  replicaCount: 1
  port: 3100
  resources: { requests: { cpu: 100m, memory: 256Mi }, limits: { cpu: 1, memory: 512Mi } }
  ingress:
    enabled: false
serviceAccount:
  create: true
postgres:
  host: common-services-postgresql.common-services.svc.cluster.local
  port: 5432
redis:
  host: common-services-redis-master.common-services.svc.cluster.local
  port: 6379
embedding:
  baseUrl: "http://signals-search-embeddings:80/v1"
  rerankBaseUrl: "http://signals-search-embeddings:8081"
  model: "BAAI/bge-m3"
  dim: "1024"
config:
  INGEST_STREAM: "signals:item-events"
  INGEST_CONSUMER_GROUP: "signals-search"
  SWEEP_INTERVAL_MS: "60000"
  SWEEP_BATCH_SIZE: "200"
secrets:
  create: true
  existingSecret: dpg-search-secrets
  data:
    POSTGRES_USER: "dpg"
    POSTGRES_DB: "dpg"
    POSTGRES_PASSWORD: ""
    REDIS_PASSWORD: ""
    EMBEDDING_API_KEY: ""
```

- [ ] **Step 3: `templates/_helpers.tpl`**

```yaml
{{- define "search.name" -}}search{{- end -}}
{{- define "search.fullname" -}}{{ .Release.Name }}-search{{- end -}}
{{- define "search.labels" -}}
app.kubernetes.io/name: {{ include "search.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "search.selectorLabels" -}}
app.kubernetes.io/name: {{ include "search.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "search.serviceAccountName" -}}{{ include "search.fullname" . }}{{- end -}}
{{- define "search.secretName" -}}{{ .Values.secrets.existingSecret | default (printf "%s-secrets" (include "search.fullname" .)) }}{{- end -}}
```

- [ ] **Step 4: `templates/secret.yaml`**

```yaml
{{- if .Values.secrets.create }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "search.secretName" . }}
  labels: {{- include "search.labels" . | nindent 4 }}
type: Opaque
stringData:
  {{- range $k, $v := .Values.secrets.data }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
{{- end }}
```

- [ ] **Step 5: `templates/configmap.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "search.fullname" . }}
  labels: {{- include "search.labels" . | nindent 4 }}
data:
  POSTGRES_HOST: {{ .Values.postgres.host | quote }}
  POSTGRES_PORT: {{ .Values.postgres.port | quote }}
  REDIS_HOST: {{ .Values.redis.host | quote }}
  REDIS_PORT: {{ .Values.redis.port | quote }}
  EMBEDDING_BASE_URL: {{ .Values.embedding.baseUrl | quote }}
  RERANK_BASE_URL: {{ .Values.embedding.rerankBaseUrl | quote }}
  EMBEDDING_MODEL: {{ .Values.embedding.model | quote }}
  EMBEDDING_DIM: {{ .Values.embedding.dim | quote }}
  {{- range $k, $v := .Values.config }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
```

- [ ] **Step 6: `templates/deployment-worker.yaml`** (composes `DATABASE_URL`/`REDIS_URL` from secret + configmap, mirroring the aggregator worker)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "search.fullname" . }}-worker
  labels: {{- include "search.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.worker.replicaCount }}
  selector:
    matchLabels:
      {{- include "search.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: worker
  template:
    metadata:
      labels:
        {{- include "search.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: worker
    spec:
      serviceAccountName: {{ include "search.serviceAccountName" . }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets: {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: worker
          image: "{{ .Values.workerImage.repository }}:{{ .Values.workerImage.tag }}"
          imagePullPolicy: {{ .Values.workerImage.pullPolicy }}
          command: ["node", "dist/worker/main.js"]
          envFrom:
            - configMapRef: { name: {{ include "search.fullname" . }} }
          env:
            - name: POSTGRES_USER
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: POSTGRES_USER } }
            - name: POSTGRES_DB
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: POSTGRES_DB } }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: POSTGRES_PASSWORD } }
            - name: REDIS_PASSWORD
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: REDIS_PASSWORD } }
            - name: EMBEDDING_API_KEY
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: EMBEDDING_API_KEY } }
            - name: DATABASE_URL
              value: "postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)"
            - name: REDIS_URL
              value: "redis://:$(REDIS_PASSWORD)@$(REDIS_HOST):$(REDIS_PORT)"
          resources: {{- toYaml .Values.worker.resources | nindent 12 }}
```

- [ ] **Step 7: `templates/deployment-api.yaml`** (same env wiring; serves HTTP on `api.port`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "search.fullname" . }}-api
  labels: {{- include "search.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.api.replicaCount }}
  selector:
    matchLabels:
      {{- include "search.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: api
  template:
    metadata:
      labels:
        {{- include "search.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: api
    spec:
      serviceAccountName: {{ include "search.serviceAccountName" . }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets: {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: api
          image: "{{ .Values.apiImage.repository }}:{{ .Values.apiImage.tag }}"
          imagePullPolicy: {{ .Values.apiImage.pullPolicy }}
          command: ["node", "dist/api/main.js"]
          ports:
            - name: http
              containerPort: {{ .Values.api.port }}
          envFrom:
            - configMapRef: { name: {{ include "search.fullname" . }} }
          env:
            - name: API_PORT
              value: {{ .Values.api.port | quote }}
            - name: POSTGRES_USER
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: POSTGRES_USER } }
            - name: POSTGRES_DB
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: POSTGRES_DB } }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: POSTGRES_PASSWORD } }
            - name: REDIS_PASSWORD
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: REDIS_PASSWORD } }
            - name: EMBEDDING_API_KEY
              valueFrom: { secretKeyRef: { name: {{ include "search.secretName" . }}, key: EMBEDDING_API_KEY } }
            - name: DATABASE_URL
              value: "postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)"
            - name: REDIS_URL
              value: "redis://:$(REDIS_PASSWORD)@$(REDIS_HOST):$(REDIS_PORT)"
          readinessProbe:
            httpGet: { path: /health, port: http }
            initialDelaySeconds: 10
            periodSeconds: 10
          resources: {{- toYaml .Values.api.resources | nindent 12 }}
```

- [ ] **Step 8: `templates/service.yaml`** (fronts the API; DNS `signals-search`)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "search.fullname" . }}
  labels: {{- include "search.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  selector:
    {{- include "search.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: api
  ports:
    - name: http
      port: {{ .Values.api.port }}
      targetPort: http
```

- [ ] **Step 9: Lint** (after Task 4 wires the dep)

Run: `helm lint helm/signals/charts/search`
Expected: "0 chart(s) failed".

- [ ] **Step 10: Commit**

```bash
git add helm/signals/charts/search
git commit -m "feat: search subchart (ingestion worker + query API)"
```

---

### Task 4: Wire both subcharts into the `signals` umbrella + values

**Files:**
- Modify: `helm/signals/Chart.yaml` (add two dependencies)
- Modify: `helm/signals/values.yaml` (add `search` + `search-embeddings` blocks)
- Modify: `opentofu/aws/modules/output-file/signals-values.yaml.tfpl` (pass DB/Redis passwords into the search secret)

- [ ] **Step 1: Add dependencies** to `helm/signals/Chart.yaml` (append to the `dependencies:` list):

```yaml
  - name: dpg-search
    version: 0.1.0
    repository: "file://../search"
    alias: search
    condition: search.enabled
  - name: dpg-search-embeddings
    version: 0.1.0
    repository: "file://../search-embeddings"
    alias: search-embeddings
    condition: search-embeddings.enabled
```

- [ ] **Step 2: Add umbrella values** to `helm/signals/values.yaml` (top-level keys matching the aliases):

```yaml
search-embeddings:
  enabled: true
  imagePullSecrets:
    - name: ghcr-pull

search:
  enabled: true
  imagePullSecrets:
    - name: ghcr-pull
  postgres:
    host: common-services-postgresql.common-services.svc.cluster.local
  redis:
    host: common-services-redis-master.common-services.svc.cluster.local
  embedding:
    baseUrl: "http://signals-search-embeddings:80/v1"
    rerankBaseUrl: "http://signals-search-embeddings:8081"
  secrets:
    create: true
    existingSecret: dpg-search-secrets
    data:
      POSTGRES_USER: "dpg"
      POSTGRES_DB: "dpg"
      POSTGRES_PASSWORD: ""
      REDIS_PASSWORD: ""
      EMBEDDING_API_KEY: ""
```

- [ ] **Step 3: Pass real secrets via the opentofu values template** — in `opentofu/aws/modules/output-file/signals-values.yaml.tfpl`, add a `search:` block that injects the generated passwords (reuse the same `signals_postgres_password` / `signals_redis_password` already templated for the api block):

```yaml
search:
  secrets:
    create: true
    existingSecret: dpg-search-secrets
    data:
      POSTGRES_USER: "dpg"
      POSTGRES_DB: "dpg"
      POSTGRES_PASSWORD: "${signals_postgres_password}"
      REDIS_PASSWORD: "${signals_redis_password}"
      EMBEDDING_API_KEY: ""
```

- [ ] **Step 4: Rebuild chart deps**

Run: `helm dependency update helm/signals`
Expected: pulls the two `file://` subcharts into `helm/signals/charts/` lockfile; "Update Complete".

- [ ] **Step 5: Verify the umbrella renders both services**

Run: `helm template signals helm/signals | grep -E "kind: (Deployment|Service)" -n | grep -Ei "search"` — or more precisely:
```bash
helm template signals helm/signals | grep -cE "name: signals-search(-embeddings)?(-worker|-api)?$"
```
Expected: ≥ `4` (search-embeddings Deployment+Service, search worker+api Deployments, search Service).

- [ ] **Step 6: Verify the embedding base URL is wired into the search config**

Run: `helm template signals helm/signals | grep "signals-search-embeddings:80/v1"`
Expected: at least one match (the `EMBEDDING_BASE_URL` in the search ConfigMap).

- [ ] **Step 7: Lint the umbrella**

Run: `helm lint helm/signals`
Expected: "0 chart(s) failed".

- [ ] **Step 8: Commit**

```bash
git add helm/signals/Chart.yaml helm/signals/values.yaml opentofu/aws/modules/output-file/signals-values.yaml.tfpl
git commit -m "feat: wire search + search-embeddings into signals umbrella + secrets"
```

---

### Task 5: Confirm deploy order (no install.sh change) + dry-run

**Files:** none (verification only)

- [ ] **Step 1: Confirm search deploys with signals** — because `search` and `search-embeddings` are subcharts of the `signals` umbrella, the existing `deploy_signals` step (`helm upgrade --install signals ...`) deploys them. No new function in `opentofu/aws/template/install.sh` is required, and the order (`common-services → signals → aggregator`) already places extensions (Task 1) before the search workloads.

Verify the function is unchanged and references the umbrella:

Run: `grep -A3 "function deploy_signals()" opentofu/aws/template/install.sh`
Expected: shows `helm upgrade --install "$SIGNALS_REL" "$SIGNALS_DIR" ...` (no edit needed).

- [ ] **Step 2: Full-umbrella server-side dry-run** (requires a reachable cluster/kubeconfig; otherwise rely on Task 4 `helm template`)

Run: `helm upgrade --install signals helm/signals -n signals --dry-run=server 2>&1 | tail -5`
Expected: renders without error; release plan includes the search + search-embeddings objects. (If no cluster is available, mark this step N/A and rely on the Task 4 `helm template` + `helm lint` evidence.)

- [ ] **Step 3: Commit** (docs/notes only, if any)

```bash
git commit --allow-empty -m "chore: confirm search deploys via signals umbrella (no install.sh change)"
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage (Plan 4 portion):** extensions enabled on both self-hosted (bootstrap) and RDS/Aurora (migrate-job admin branch) paths ✓ (Task 1); TEI service CPU, embeddings + reranker co-located in one pod ✓ (Task 2); search worker + API subchart with DB/Redis/embedding wiring ✓ (Task 3); umbrella deps + values + opentofu secret passthrough ✓ (Task 4); deploy order confirmed without an `install.sh` change ✓ (Task 5).
- **Decisions matched to spec:** TEI = **CPU, one pod, two containers** (embed `BAAI/bge-m3` :80, rerank `BAAI/bge-reranker-v2-m3` :8081). Search is a **subchart of the signals umbrella** (mirrors api/match-score), so it shares the `signals` release/namespace and deploys in-order automatically.
- **Cross-plan dependencies (called out, not hidden):** image repos `signals-search/worker` + `signals-search/api` must exist from signals-search CI (Plans 1–2); the `item_search` DDL is applied by the existing api migrate-job from Signals-DPG `schema.sql` (Plan 3 Task 1). Container entrypoints assume `dist/worker/main.js` and `dist/api/main.js` — align these with the signals-search Dockerfiles when those are written.
- **RDS/Aurora caveat:** parameter-group allowlisting + engine-version pin for pgvector/postgis is a console/Terraform action tracked in #22, intentionally outside this Helm plan.
- **Verification model:** infra tasks use `helm lint` + `helm template … | grep` with expected counts instead of unit tests; the optional server-side dry-run (Task 5 Step 2) is marked N/A-able when no cluster is reachable.
- **Naming consistency:** service DNS `signals-search` (API) and `signals-search-embeddings` (TEI, ports 80/8081) are referenced consistently across Tasks 2–4 and match the `EMBEDDING_BASE_URL` the worker/API consume.
