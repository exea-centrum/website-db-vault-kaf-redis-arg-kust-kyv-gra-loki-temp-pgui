#!/usr/bin/env bash
set -euo pipefail

# Final chatgpt.sh - All-in-one manifest generator (production-ready defaults)
# Generates manifests/base/* for ArgoCD (Kustomize), Vault, Postgres, Redis, Kafka, Grafana (separate secret), Prometheus, Loki, Tempo, Kyverno.
# Usage: ./chatgpt.sh generate

APP_NAME="website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat"
ORG="exea-centrum"
IMAGE="ghcr.io/${ORG}/${APP_NAME}:latest"
NAMESPACE="davtrowebdbvault"
REPO_URL="https://github.com/${ORG}/${APP_NAME}.git"

ROOT_DIR="$(pwd)"
MANIFESTS_DIR="${ROOT_DIR}/manifests"
BASE_DIR="${MANIFESTS_DIR}/base"
WORKFLOW_DIR="${ROOT_DIR}/.github/workflows"

info(){ echo -e "[chatgpt.sh] $*"; }
mkdir_p(){ mkdir -p "$@"; }

generate_structure(){
  info "creating directories..."
  mkdir_p "${BASE_DIR}"
  mkdir_p "${WORKFLOW_DIR}"
}

generate_github_actions(){
  info "writing .github/workflows/ci.yml"
  cat > "${WORKFLOW_DIR}/ci.yml" <<'GHA'
name: CI/CD Build & Push

on:
  push:
    branches: [ "main" ]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Set up QEMU
        uses: docker/setup-qemu-action@v2
      - name: Set up Buildx
        uses: docker/setup-buildx-action@v2
      - name: Log in to GHCR
        uses: docker/login-action@v2
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GHCR_PAT }}
      - name: Build and push image
        uses: docker/build-push-action@v4
        with:
          context: .
          push: true
          tags: ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat:${{ github.sha }}
GHA
}

generate_kustomization(){
  info "writing kustomization.yaml"
  cat > "${BASE_DIR}/kustomization.yaml" <<K
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NAMESPACE}

resources:
  - service-accounts.yaml
  - vault-config.yaml
  - vault-server.yaml
  - vault-agent-injector.yaml
  - secret-fallback.yaml
  - grafana-secret.yaml
  - postgres.yaml
  - pgadmin.yaml
  - redis.yaml
  - kafka.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - prometheus-config.yaml
  - prometheus-deployment.yaml
  - grafana-deployment.yaml
  - loki-config.yaml
  - loki-deployment.yaml
  - promtail-config.yaml
  - promtail-deployment.yaml
  - tempo-config.yaml
  - tempo-deployment.yaml
  - kyverno-policy.yaml
  - argocd-app.yaml
K
}

generate_service_accounts(){
  info "writing service-accounts.yaml"
  cat > "${BASE_DIR}/service-accounts.yaml" <<SA
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
imagePullSecrets:
  - name: ghcr-pull-secret
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault
  namespace: ${NAMESPACE}
SA
}

generate_vault(){
  info "writing vault manifests"
  cat > "${BASE_DIR}/vault-config.yaml" <<VC
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: ${NAMESPACE}
data:
  vault.hcl: |
    storage "file" {
      path = "/vault/data"
    }
    listener "tcp" {
      address = "0.0.0.0:8200"
      tls_disable = "true"
    }
    ui = true
    disable_mlock = true
VC

  cat > "${BASE_DIR}/vault-server.yaml" <<VS
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault
  namespace: ${NAMESPACE}
spec:
  serviceName: vault
  replicas: 1
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      serviceAccountName: vault
      containers:
        - name: vault
          image: hashicorp/vault:1.15.3
          args: ["server","-config=/vault/config/vault.hcl"]
          ports:
            - containerPort: 8200
          livenessProbe:
            httpGet:
              path: /v1/sys/health?standbyok=true
              port: 8200
            initialDelaySeconds: 15
            periodSeconds: 20
          volumeMounts:
            - name: vault-config
              mountPath: /vault/config
            - name: vault-data
              mountPath: /vault/data
      volumes:
        - name: vault-config
          configMap:
            name: vault-config
  volumeClaimTemplates:
    - metadata:
        name: vault-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 8200
  selector:
    app: vault
VS

  cat > "${BASE_DIR}/vault-agent-injector.yaml" <<VAI
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-agent-injector
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault-agent-injector
  template:
    metadata:
      labels:
        app: vault-agent-injector
    spec:
      containers:
        - name: vault-k8s
          image: hashicorp/vault-k8s:1.9.0
          args: ["controller"]
VAI
}

generate_secret_fallback(){
  info "writing fallback secret db-secret"
  cat > "${BASE_DIR}/secret-fallback.yaml" <<SF
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  username: postgres
  password: postgres123
SF
}

generate_grafana_secret(){
  info "writing grafana-secret.yaml"
  cat > "${BASE_DIR}/grafana-secret.yaml" <<GS
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  admin-user: admin
  admin-password: grafana123
GS
}

generate_grafana_deployment(){
  info "writing grafana-deployment.yaml (references grafana-secret)"
  cat > "${BASE_DIR}/grafana-deployment.yaml" <<GD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:11.1.0
          env:
            - name: GF_SECURITY_ADMIN_USER
              valueFrom:
                secretKeyRef:
                  name: grafana-secret
                  key: admin-user
            - name: GF_SECURITY_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: grafana-secret
                  key: admin-password
          ports:
            - containerPort: 3000
          volumeMounts:
            - name: grafana-data
              mountPath: /var/lib/grafana
  volumeClaimTemplates:
    - metadata:
        name: grafana-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 3000
  selector:
    app: grafana
GD
}

generate_postgres(){
  info "writing postgres"
  cat > "${BASE_DIR}/postgres.yaml" <<PG
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: ${NAMESPACE}
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: appdb
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: db-secret
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-secret
                  key: password
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: pgdata
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 5432
  selector:
    app: postgres
PG
}

generate_pgadmin(){
  info "writing pgadmin"
  cat > "${BASE_DIR}/pgadmin.yaml" <<PGA
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgadmin
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgadmin
  template:
    metadata:
      labels:
        app: pgadmin
    spec:
      containers:
        - name: pgadmin
          image: dpage/pgadmin4:8.8
          ports:
            - containerPort: 80
          env:
            - name: PGADMIN_DEFAULT_EMAIL
              value: admin@example.com
            - name: PGADMIN_DEFAULT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: grafana-secret
                  key: admin-password
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 80
  selector:
    app: pgadmin
PGA
}

generate_redis(){
  info "writing redis"
  cat > "${BASE_DIR}/redis.yaml" <<R
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
  namespace: ${NAMESPACE}
spec:
  serviceName: redis
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7
          ports:
            - containerPort: 6379
          args: ["--appendonly", "yes"]
          volumeMounts:
            - name: redis-data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: redis-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 6379
  selector:
    app: redis
R
}

generate_kafka(){
  info "writing kafka + zookeeper"
  cat > "${BASE_DIR}/kafka.yaml" <<KAF
# zookeeper
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: zookeeper
  namespace: ${NAMESPACE}
spec:
  serviceName: zookeeper
  replicas: 1
  selector:
    matchLabels:
      app: zookeeper
  template:
    metadata:
      labels:
        app: zookeeper
    spec:
      containers:
        - name: zookeeper
          image: bitnami/zookeeper:3.9.2
          ports:
            - containerPort: 2181
---
apiVersion: v1
kind: Service
metadata:
  name: zookeeper
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 2181
  selector:
    app: zookeeper

# kafka (single node)
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: ${NAMESPACE}
spec:
  serviceName: kafka
  replicas: 1
  selector:
    matchLabels:
      app: kafka
  template:
    metadata:
      labels:
        app: kafka
    spec:
      containers:
        - name: kafka
          image: bitnami/kafka:3.8.0
          env:
            - name: KAFKA_CFG_ZOOKEEPER_CONNECT
              value: zookeeper:2181
            - name: ALLOW_PLAINTEXT_LISTENER
              value: "yes"
          ports:
            - containerPort: 9092
          volumeMounts:
            - name: kafka-data
              mountPath: /bitnami/kafka
  volumeClaimTemplates:
    - metadata:
        name: kafka-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 9092
  selector:
    app: kafka
KAF
}

generate_app_deployment(){
  info "writing app deployment + service"
  cat > "${BASE_DIR}/deployment.yaml" <<DEP
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-app
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP_NAME}-app
  template:
    metadata:
      labels:
        app: ${APP_NAME}-app
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "${APP_NAME}-role"
        vault.hashicorp.com/agent-inject-secret-config.txt: "secret/data/${APP_NAME}/app"
        vault.hashicorp.com/agent-inject-template-config.txt: |
          {{- with secret "secret/data/${APP_NAME}/app" -}}
          DATABASE_URL=postgresql://{{ .Data.data.username }}:{{ .Data.data.password }}@postgres:5432/appdb
          REDIS_URL=redis://:{{ .Data.data.redis_password }}@redis:6379
          KAFKA_BROKER=kafka:9092
          SECRET_KEY_BASE={{ .Data.data.secret_key_base }}
          {{- end }}
    spec:
      serviceAccountName: ${APP_NAME}
      containers:
        - name: app
          image: ${IMAGE}
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
DEP

  cat > "${BASE_DIR}/service.yaml" <<SVC
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-svc
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${APP_NAME}-app
  ports:
    - port: 80
      targetPort: 8080
SVC
}

generate_ingress(){
  info "writing ingress"
  cat > "${BASE_DIR}/ingress.yaml" <<ING
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}-ingress
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  rules:
    - host: ${APP_NAME}.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${APP_NAME}-svc
                port:
                  number: 80
ING
}

generate_prometheus(){
  info "writing prometheus"
  cat > "${BASE_DIR}/prometheus-config.yaml" <<PC
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: ${NAMESPACE}
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: 'kubernetes-pods'
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true
PC

  cat > "${BASE_DIR}/prometheus-deployment.yaml" <<PD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
        - name: prometheus
          image: prom/prometheus:v2.54.0
          args:
            - "--config.file=/etc/prometheus/prometheus.yml"
            - "--storage.tsdb.path=/prometheus"
          ports:
            - containerPort: 9090
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
            - name: data
              mountPath: /prometheus
      volumes:
        - name: config
          configMap:
            name: prometheus-config
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 9090
  selector:
    app: prometheus
PD
}

generate_loki_promtail(){
  info "writing loki & promtail"
  cat > "${BASE_DIR}/loki-config.yaml" <<LKC
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: ${NAMESPACE}
data:
  loki-config.yaml: |
    auth_enabled: false
    server:
      http_listen_port: 3100
    storage_config:
      boltdb_shipper:
        active_index_directory: /loki/index
        cache_location: /loki/cache
      filesystem:
        directory: /loki/chunks
LKC

  cat > "${BASE_DIR}/loki-deployment.yaml" <<LKD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
        - name: loki
          image: grafana/loki:2.9.5
          args: ["-config.file=/etc/loki/loki-config.yaml"]
          ports:
            - containerPort: 3100
          volumeMounts:
            - name: config
              mountPath: /etc/loki
            - name: data
              mountPath: /loki
      volumes:
        - name: config
          configMap:
            name: loki-config
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 3100
  selector:
    app: loki
LKD

  cat > "${BASE_DIR}/promtail-config.yaml" <<PTC
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: ${NAMESPACE}
data:
  promtail-config.yaml: |
    server:
      http_listen_port: 9080
    positions:
      filename: /tmp/positions.yaml
    clients:
      - url: http://loki:3100/loki/api/v1/push
    scrape_configs:
      - job_name: kubernetes-pods
        static_configs:
          - targets: ['localhost']
            labels:
              job: varlogs
              __path__: /var/log/*log
PTC

  cat > "${BASE_DIR}/promtail-deployment.yaml" <<PTD
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: ${NAMESPACE}
spec:
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      containers:
        - name: promtail
          image: grafana/promtail:3.0.0
          args: ["-config.file=/etc/promtail/promtail-config.yaml"]
          volumeMounts:
            - name: config
              mountPath: /etc/promtail
            - name: varlog
              mountPath: /var/log
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: promtail-config
        - name: varlog
          hostPath:
            path: /var/log
---
apiVersion: v1
kind: Service
metadata:
  name: promtail
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 9080
  selector:
    app: promtail
PTD
}

generate_tempo(){
  info "writing tempo"
  cat > "${BASE_DIR}/tempo-config.yaml" <<TC
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: ${NAMESPACE}
data:
  tempo-config.yaml: |
    server:
      http_listen_port: 3200
    storage:
      trace:
        backend: local
        local:
          path: /tmp/tempo/traces
TC

  cat > "${BASE_DIR}/tempo-deployment.yaml" <<TD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tempo
  template:
    metadata:
      labels:
        app: tempo
    spec:
      containers:
        - name: tempo
          image: grafana/tempo:2.5.0
          args: ["-config.file=/etc/tempo/tempo-config.yaml"]
          ports:
            - containerPort: 3200
          volumeMounts:
            - name: config
              mountPath: /etc/tempo
      volumes:
        - name: config
          configMap:
            name: tempo-config
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: ${NAMESPACE}
spec:
  ports:
    - port: 3200
  selector:
    app: tempo
TD
}

generate_kyverno(){
  info "writing kyverno policy"
  cat > "${BASE_DIR}/kyverno-policy.yaml" <<KY
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-namespace-label
spec:
  validationFailureAction: enforce
  background: true
  rules:
    - name: require-namespace-label
      match:
        resources:
          kinds:
            - Namespace
      validate:
        message: "Namespace must have label 'team'."
        pattern:
          metadata:
            labels:
              team: "?*"
KY
}

generate_argocd_app(){
  info "writing argocd-app.yaml (kustomize source only)"
  cat > "${BASE_DIR}/argocd-app.yaml" <<AA
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: main
    path: manifests/base
    kustomize:
      buildOptions: --load-restrictor=LoadRestrictionsNone
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ApplyOutOfSyncOnly=true
      - Validate=false
  retry:
    limit: 5
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 2m
AA
}

generate_readme(){
  info "writing README.md"
  cat > "${ROOT_DIR}/README.md" <<MD
# ${APP_NAME} — All-in-One GitOps Stack (final)

Namespace: ${NAMESPACE}
Repo: ${REPO_URL}

Usage:
  chmod +x chatgpt.sh
  ./chatgpt.sh generate
  git add .
  git commit -m "init all-in-one"
  git push origin main

Notes:
- grafana-secret is a single file manifests/base/grafana-secret.yaml (no duplicates).
- Ensure GHCR_PAT is configured in GitHub repo secrets for pushing images.
- Vault here runs with TLS disabled for quick testing — configure TLS and a persistent storage backend for production.
MD
}

generate_all(){
  generate_structure
  generate_github_actions
  generate_kustomization
  generate_service_accounts
  generate_vault
  generate_secret_fallback
  generate_grafana_secret
  generate_grafana_deployment
  generate_postgres
  generate_pgadmin
  generate_redis
  generate_kafka
  generate_app_deployment
  generate_ingress
  generate_prometheus
  generate_loki_promtail
  generate_tempo
  generate_kyverno
  generate_argocd_app
  generate_readme
  info "All manifests generated in ${BASE_DIR}"
}

case "${1:-}" in
  generate)
    generate_all
    ;;
  help|-h|--help)
    echo "Usage: $0 generate"
    ;;
  *)
    echo "No command provided. Use: $0 generate"
    exit 1
    ;;
esac