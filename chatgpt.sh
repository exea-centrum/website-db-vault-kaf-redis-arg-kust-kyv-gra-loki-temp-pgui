#!/usr/bin/env bash
set -euo pipefail

# Unified GitOps Stack Generator - FastAPI + Full Stack
# Generates complete application with ArgoCD, Vault, Postgres, Redis, Kafka (KRaft), Grafana, Prometheus, Loki, Tempo, Kyverno

# UŻYWAMY KRÓTKIEJ NAZWY
PROJECT="webstack-gitops"
NAMESPACE="${PROJECT}-ns"
ORG="exea-centrum"
REGISTRY="ghcr.io/${ORG}/${PROJECT}"
REPO_URL="https://github.com/${ORG}/${PROJECT}.git"
KAFKA_CLUSTER_ID="4mUj5vFk3tW7pY0iH2gR8qL6eD9oB1cZ"

ROOT_DIR="$(pwd)"
APP_DIR="app"
MANIFESTS_DIR="${ROOT_DIR}/manifests"
BASE_DIR="${MANIFESTS_DIR}/base"
WORKFLOW_DIR="${ROOT_DIR}/.github/workflows"

info(){ echo -e "🔧 [unified] $*"; }
mkdir_p(){ mkdir -p "$@"; }

# ==============================
# DIRECTORY STRUCTURE
# ==============================
generate_structure(){
  info "Creating directory structure..."
  mkdir_p "$APP_DIR/templates" "$BASE_DIR" "$WORKFLOW_DIR"
}

# ==============================
# FASTAPI APPLICATION
# ==============================
generate_fastapi_app(){
  info "Generating FastAPI application with Kafka and Tracing..."
  
  # main.py
  cat << 'EOF' > "$APP_DIR/main.py"
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
import logging

app = FastAPI(title="Personal Website")
templates = Jinja2Templates(directory="templates")
logging.basicConfig(level=logging.INFO)

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/health")
async def health_check():
    return {"status": "healthy", "service": "fastapi"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
EOF

  # requirements.txt
  cat << 'EOF' > "$APP_DIR/requirements.txt"
fastapi==0.104.1
uvicorn==0.24.0
jinja2==3.1.2
EOF
}

generate_html_template(){
  info "Generating HTML template..."
  cat << 'HTMLEOF' > "$APP_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Personal Website</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-100 min-h-screen">
    <header class="bg-blue-600 text-white p-4">
        <div class="container mx-auto">
            <h1 class="text-3xl font-bold">Personal Website</h1>
        </div>
    </header>
    <main class="container mx-auto p-6">
        <div class="bg-white rounded-lg shadow-md p-6">
            <h2 class="text-2xl font-bold mb-4">Welcome!</h2>
            <p class="text-gray-700">This is a simple FastAPI application deployed with GitOps.</p>
        </div>
    </main>
    <footer class="bg-gray-800 text-white p-4 mt-8">
        <div class="container mx-auto text-center">
            <p>&copy; 2024 Personal Website</p>
        </div>
    </footer>
</body>
</html>
HTMLEOF
}

# ==============================
# DOCKERFILE
# ==============================
generate_dockerfile(){
  info "Generating Dockerfile..."
  cat << 'EOF' > "${ROOT_DIR}/Dockerfile"
FROM python:3.11-slim

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ /app/

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF
}

# ==============================
# GITHUB ACTIONS
# ==============================
generate_github_actions(){
  info "Generating GitHub Actions workflow..."
  cat << EOF > "$WORKFLOW_DIR/ci-cd.yaml"
name: CI/CD Pipeline

on:
  push:
    branches: [main]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      
      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}
      
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: $REGISTRY:latest
EOF
}

# ==============================
# KUBERNETES MANIFESTS
# ==============================

# 1. FastAPI Application
generate_k8s_base(){
  info "Generating app-deployment.yaml..."
  cat << EOF > "$BASE_DIR/app-deployment.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fastapi-app
  labels:
    app: $PROJECT
    component: fastapi
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: fastapi
  template:
    metadata:
      labels:
        app: $PROJECT
        component: fastapi
    spec:
      containers:
      - name: app
        image: $REGISTRY:latest
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          value: "postgresql://webuser:webpass@postgres:5432/webdb"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: fastapi-service
  labels:
    app: $PROJECT
    component: fastapi
spec:
  ports:
  - port: 80
    targetPort: 8000
  selector:
    app: $PROJECT
    component: fastapi
EOF
}

# 2. PostgreSQL Database
generate_postgres(){
  info "Generating postgres.yaml..."
  cat << EOF > "$BASE_DIR/postgres.yaml"
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels:
    app: $PROJECT
    component: postgres
spec:
  ports:
  - port: 5432
  selector:
    app: $PROJECT
    component: postgres
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  labels:
    app: $PROJECT
    component: postgres
spec:
  serviceName: "postgres"
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: postgres
  template:
    metadata:
      labels:
        app: $PROJECT
        component: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_USER
          value: "webuser"
        - name: POSTGRES_PASSWORD
          value: "webpass"
        - name: POSTGRES_DB
          value: "webdb"
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          exec:
            command:
            - sh
            - -c
            - exec pg_isready -U webuser -d webdb -h 127.0.0.1
          initialDelaySeconds: 30
          periodSeconds: 10
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 5Gi
EOF
}

# 3. pgAdmin
generate_pgadmin(){
  info "Generating pgadmin.yaml..."
  cat << EOF > "$BASE_DIR/pgadmin.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgadmin
  labels:
    app: $PROJECT
    component: pgadmin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: pgadmin
  template:
    metadata:
      labels:
        app: $PROJECT
        component: pgadmin
    spec:
      containers:
      - name: pgadmin
        image: dpage/pgadmin4:latest
        ports:
        - containerPort: 80
        env:
        - name: PGADMIN_DEFAULT_EMAIL
          value: "admin@admin.com"
        - name: PGADMIN_DEFAULT_PASSWORD
          value: "admin"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        readinessProbe:
          httpGet:
            path: /login
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin-service
  labels:
    app: $PROJECT
    component: pgadmin
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: $PROJECT
    component: pgadmin
EOF
}

# 4. Vault - POPRAWIONY
generate_vault(){
  info "Generating vault.yaml..."
  cat << EOF > "$BASE_DIR/vault.yaml"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-sa
  labels:
    app: $PROJECT
    component: vault
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  labels:
    app: $PROJECT
    component: vault
spec:
  ports:
  - port: 8200
    targetPort: 8200
  selector:
    app: $PROJECT
    component: vault
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault
  labels:
    app: $PROJECT
    component: vault
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: vault
  template:
    metadata:
      labels:
        app: $PROJECT
        component: vault
    spec:
      serviceAccountName: vault-sa
      containers:
      - name: vault
        image: hashicorp/vault:1.15.0
        securityContext:
          capabilities:
            add:
            - IPC_LOCK
        args:
        - server
        - -dev
        - -dev-listen-address=0.0.0.0:8200
        - -dev-root-token-id=root
        ports:
        - containerPort: 8200
        env:
        - name: VAULT_DEV_ROOT_TOKEN_ID
          value: "root"
        - name: VAULT_ADDR
          value: "http://0.0.0.0:8200"
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          httpGet:
            path: /v1/sys/health
            port: 8200
          initialDelaySeconds: 5
          periodSeconds: 5
EOF
}

# 5. Redis
generate_redis(){
  info "Generating redis.yaml..."
  cat << EOF > "$BASE_DIR/redis.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    app: $PROJECT
    component: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: redis
  template:
    metadata:
      labels:
        app: $PROJECT
        component: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        command: ["redis-server", "--appendonly", "yes"]
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  labels:
    app: $PROJECT
    component: redis
spec:
  ports:
  - port: 6379
    targetPort: 6379
  selector:
    app: $PROJECT
    component: redis
EOF
}

# 6. Kafka KRaft - POPRAWIONY
generate_kafka(){
  info "Generating kafka.yaml..."
  cat << EOF > "$BASE_DIR/kafka.yaml"
apiVersion: v1
kind: Service
metadata:
  name: kafka
  labels:
    app: $PROJECT
    component: kafka
spec:
  ports:
  - port: 9092
  selector:
    app: $PROJECT
    component: kafka
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  labels:
    app: $PROJECT
    component: kafka
spec:
  serviceName: "kafka"
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: kafka
  template:
    metadata:
      labels:
        app: $PROJECT
        component: kafka
    spec:
      containers:
      - name: kafka
        image: apache/kafka:3.7.0
        env:
        - name: KAFKA_NODE_ID
          value: "1"
        - name: KAFKA_PROCESS_ROLES
          value: "controller,broker"
        - name: KAFKA_CONTROLLER_QUORUM_VOTERS
          value: "1@kafka:9093"
        - name: KAFKA_LISTENERS
          value: "PLAINTEXT://:9092,CONTROLLER://:9093"
        - name: KAFKA_ADVERTISED_LISTENERS
          value: "PLAINTEXT://kafka:9092"
        - name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP
          value: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
        - name: KAFKA_CONTROLLER_LISTENER_NAMES
          value: "CONTROLLER"
        - name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR
          value: "1"
        - name: CLUSTER_ID
          value: "$KAFKA_CLUSTER_ID"
        ports:
        - containerPort: 9092
        - containerPort: 9093
        volumeMounts:
        - name: kafka-data
          mountPath: /tmp/kraft-combined-logs
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
  volumeClaimTemplates:
  - metadata:
      name: kafka-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
EOF
}

# 7. Prometheus - DODANA BRAKUJĄCA FUNKCJA
generate_prometheus(){
  info "Generating prometheus.yaml..."
  cat << EOF > "$BASE_DIR/prometheus-config.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  labels:
    app: $PROJECT
    component: prometheus
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
    - job_name: 'prometheus'
      static_configs:
      - targets: ['localhost:9090']
    - job_name: 'fastapi'
      static_configs:
      - targets: ['fastapi-service:8000']
EOF

  cat << EOF > "$BASE_DIR/prometheus.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  labels:
    app: $PROJECT
    component: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: prometheus
  template:
    metadata:
      labels:
        app: $PROJECT
        component: prometheus
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        args:
        - "--config.file=/etc/prometheus/prometheus.yml"
        - "--storage.tsdb.path=/prometheus"
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: config
        configMap:
          name: prometheus-config
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-service
  labels:
    app: $PROJECT
    component: prometheus
spec:
  ports:
  - port: 9090
    targetPort: 9090
  selector:
    app: $PROJECT
    component: prometheus
EOF
}

# 8. Grafana - DODANA BRAKUJĄCA FUNKCJA
generate_grafana(){
  info "Generating grafana.yaml..."
  cat << EOF > "$BASE_DIR/grafana-datasource.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource
  labels:
    app: $PROJECT
    component: grafana
data:
  prometheus.yaml: |
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-service:9090
      access: proxy
      isDefault: true
EOF

  cat << EOF > "$BASE_DIR/grafana.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  labels:
    app: $PROJECT
    component: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: grafana
  template:
    metadata:
      labels:
        app: $PROJECT
        component: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:latest
        ports:
        - containerPort: 3000
        env:
        - name: GF_SECURITY_ADMIN_USER
          value: "admin"
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "admin"
        volumeMounts:
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
      volumes:
      - name: datasources
        configMap:
          name: grafana-datasource
---
apiVersion: v1
kind: Service
metadata:
  name: grafana-service
  labels:
    app: $PROJECT
    component: grafana
spec:
  ports:
  - port: 80
    targetPort: 3000
  selector:
    app: $PROJECT
    component: grafana
EOF
}

# 9. Loki
generate_loki(){
  info "Generating loki.yaml..."
  cat << EOF > "$BASE_DIR/loki-config.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  labels:
    app: $PROJECT
    component: loki
data:
  loki.yaml: |
    auth_enabled: false
    server:
      http_listen_port: 3100
    common:
      path_prefix: /loki
      storage:
        filesystem:
          chunks_directory: /loki/chunks
          rules_directory: /loki/rules
      replication_factor: 1
      ring:
        kvstore:
          store: inmemory
    schema_config:
      configs:
      - from: 2020-10-24
        store: boltdb-shipper
        object_store: filesystem
        schema: v11
        index:
          prefix: index_
          period: 24h
EOF

  cat << EOF > "$BASE_DIR/loki.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  labels:
    app: $PROJECT
    component: loki
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: loki
  template:
    metadata:
      labels:
        app: $PROJECT
        component: loki
    spec:
      containers:
      - name: loki
        image: grafana/loki:2.9.0
        args:
        - -config.file=/etc/loki/loki.yaml
        ports:
        - containerPort: 3100
        volumeMounts:
        - name: config
          mountPath: /etc/loki
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: config
        configMap:
          name: loki-config
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  labels:
    app: $PROJECT
    component: loki
spec:
  ports:
  - port: 3100
    targetPort: 3100
  selector:
    app: $PROJECT
    component: loki
EOF
}

# 10. Promtail
generate_promtail(){
  info "Generating promtail.yaml..."
  cat << EOF > "$BASE_DIR/promtail-config.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  labels:
    app: $PROJECT
    component: promtail
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
      grpc_listen_port: 0
    positions:
      filename: /tmp/positions.yaml
    clients:
    - url: http://loki:3100/loki/api/v1/push
    scrape_configs:
    - job_name: system
      static_configs:
      - targets:
        - localhost
        labels:
          job: varlogs
          __path__: /var/log/*log
EOF

  cat << EOF > "$BASE_DIR/promtail.yaml"
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  labels:
    app: $PROJECT
    component: promtail
spec:
  selector:
    matchLabels:
      app: $PROJECT
      component: promtail
  template:
    metadata:
      labels:
        app: $PROJECT
        component: promtail
    spec:
      containers:
      - name: promtail
        image: grafana/promtail:2.9.0
        args:
        - -config.file=/etc/promtail/promtail.yaml
        volumeMounts:
        - name: config
          mountPath: /etc/promtail
        - name: varlog
          mountPath: /var/log
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
      volumes:
      - name: config
        configMap:
          name: promtail-config
      - name: varlog
        hostPath:
          path: /var/log
EOF
}

# 11. Tempo
generate_tempo(){
  info "Generating tempo.yaml..."
  cat << EOF > "$BASE_DIR/tempo-config.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  labels:
    app: $PROJECT
    component: tempo
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
            http:
    storage:
      trace:
        backend: local
        local:
          path: /var/tempo/traces
EOF

  cat << EOF > "$BASE_DIR/tempo.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  labels:
    app: $PROJECT
    component: tempo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
      component: tempo
  template:
    metadata:
      labels:
        app: $PROJECT
        component: tempo
    spec:
      containers:
      - name: tempo
        image: grafana/tempo:2.4.0
        args:
        - -config.file=/etc/tempo/tempo.yaml
        ports:
        - containerPort: 3200
        - containerPort: 4317
        volumeMounts:
        - name: config
          mountPath: /etc/tempo
        - name: data
          mountPath: /var/tempo
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: config
        configMap:
          name: tempo-config
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  labels:
    app: $PROJECT
    component: tempo
spec:
  ports:
  - name: http
    port: 3200
    targetPort: 3200
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  selector:
    app: $PROJECT
    component: tempo
EOF
}

# 12. Ingress
generate_ingress(){
  info "Generating ingress.yaml..."
  cat << EOF > "$BASE_DIR/ingress.yaml"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $PROJECT-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: app.$PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: fastapi-service
            port:
              number: 80
  - host: pgadmin.$PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pgadmin-service
            port:
              number: 80
  - host: grafana.$PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana-service
            port:
              number: 80
EOF
}

# 13. Kyverno Policy
generate_kyverno(){
  info "Generating kyverno-policy.yaml..."
  cat << EOF > "$BASE_DIR/kyverno-policy.yaml"
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
  labels:
    app: $PROJECT
    component: kyverno
spec:
  validationFailureAction: enforce
  rules:
  - name: check-resource-requests
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "CPU and memory requests and limits are required"
      pattern:
        spec:
          containers:
          - resources:
              requests:
                memory: "?*"
                cpu: "?*"
              limits:
                memory: "?*"
                cpu: "?*"
EOF
}

# 14. Kustomization
generate_kustomization(){
  info "Generating kustomization.yaml..."
  cat << EOF > "$BASE_DIR/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $NAMESPACE

resources:
  - app-deployment.yaml
  - postgres.yaml
  - pgadmin.yaml
  - vault.yaml
  - redis.yaml
  - kafka.yaml
  - prometheus-config.yaml
  - prometheus.yaml
  - grafana-datasource.yaml
  - grafana.yaml
  - loki-config.yaml
  - loki.yaml
  - promtail-config.yaml
  - promtail.yaml
  - tempo-config.yaml
  - tempo.yaml
  - ingress.yaml
  - kyverno-policy.yaml

commonLabels:
  app.kubernetes.io/name: $PROJECT
  app.kubernetes.io/instance: $PROJECT
  app.kubernetes.io/managed-by: kustomize
EOF
}

# 15. ArgoCD Application
generate_argocd_app(){
  info "Generating argocd-application.yaml..."
  cat << EOF > "${ROOT_DIR}/argocd-application.yaml"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $PROJECT
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: main
    path: manifests/base
  destination:
    server: https://kubernetes.default.svc
    namespace: $NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
}

# 16. README
generate_readme(){
  info "Generating README.md..."
  cat << EOF > "${ROOT_DIR}/README.md"
# 🚀 $PROJECT - Unified GitOps Stack

Complete modern microservices architecture deployed using **GitOps (ArgoCD + Kustomize)**.

## 🛠️ Technology Stack

- **Application:** FastAPI (Python)
- **Registry:** GitHub Container Registry (ghcr.io)
- **CI/CD:** GitHub Actions + ArgoCD
- **Database:** PostgreSQL
- **DB Management:** pgAdmin
- **Cache:** Redis
- **Message Broker:** Apache Kafka (KRaft)
- **Secrets Management:** HashiCorp Vault
- **Monitoring:** Prometheus + Grafana
- **Logging:** Loki + Promtail
- **Tracing:** Tempo
- **Policy Management:** Kyverno

## 🚀 Quick Start

1. **Generate the project:**
   \`\`\`bash
   chmod +x unified-stack.sh
   ./unified-stack.sh generate
   \`\`\`

2. **Initialize Git and push:**
   \`\`\`bash
   git
   