#!/usr/bin/env bash
set -euo pipefail
trap 'rc=$?; echo "❌ Error on line ${LINENO} (exit ${rc})"; exit ${rc}' ERR
IFS=$'\n\t'

# unified-stack.sh
# All-in-one generator for the teaching exercise.
# Produces:
#  - app/ (FastAPI main.py, worker.py, templates/index.html, requirements.txt)
#  - Dockerfile
#  - .github/workflows/ci-cd.yaml
#  - manifests/base/* (all listed resources)
#  - argocd-application.yaml
#  - README.md
#
# IMPORTANT: This script is intended as a generator for local development / teaching.
# Review all secrets, images and Vault dev-mode before using in any real environment.
#
# Usage:
#   chmod +x unified-stack.sh
#   ./unified-stack.sh generate

PROJECT="website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui"
NAMESPACE="davtrowebdbvault"
ORG="${ORG:-exea-centrum}"
REGISTRY="${REGISTRY:-ghcr.io/${ORG}/${PROJECT}}"
REPO_URL="${REPO_URL:-https://github.com/${ORG}/${PROJECT}.git}"
KAFKA_CLUSTER_ID="${KAFKA_CLUSTER_ID:-4mUj5vFk3tW7pY0iH2gR8qL6eD9oB1cZ}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${ROOT_DIR}/app"
TEMPLATES_DIR="${APP_DIR}/templates"
MANIFESTS_DIR="${ROOT_DIR}/manifests"
BASE_DIR="${MANIFESTS_DIR}/base"
WORKFLOW_DIR="${ROOT_DIR}/.github/workflows"

info(){ printf "🔧 [unified] %s\n" "$*"; }
warn(){ printf "⚠️  [unified] %s\n" "$*"; }
mkdir_p(){ mkdir -p "$@"; }

# --------------------------------------------------
# Create directory tree
# --------------------------------------------------
generate_structure(){
  info "Creating directories..."
  mkdir_p "$APP_DIR" "$TEMPLATES_DIR" "$BASE_DIR" "$WORKFLOW_DIR" "${ROOT_DIR}/static"
}

# --------------------------------------------------
# FastAPI app (main + worker + templates + requirements)
# --------------------------------------------------
generate_fastapi_app(){
  info "Generating FastAPI application (main.py, worker.py, templates, requirements)..."

  cat > "${APP_DIR}/main.py" <<'PY'
#!/usr/bin/env python3
# app/main.py - FastAPI frontend that queues contact messages to Redis
from fastapi import FastAPI, Form, Request, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
import os, json, time, logging
import redis
from prometheus_client import Counter
from prometheus_fastapi_instrumentator import Instrumentator

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi")

app = FastAPI(title="Personal Website - Contact Queue")
templates = Jinja2Templates(directory="templates")

app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_LIST = os.getenv("REDIS_LIST", "outgoing_messages")

CONTACT_PUSHED = Counter("app_contact_pushed_total", "Number of contact messages pushed to Redis")

def get_redis():
    return redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

Instrumentator().instrument(app).expose(app)

@app.get("/", response_class=HTMLResponse)
async def homepage(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.post("/api/contact")
async def submit_contact(email: str = Form(...), message: str = Form(...), id: str = Form(default="")):
    payload = {"id": id, "email": email, "message": message, "timestamp": time.time()}
    try:
        r = get_redis()
        r.rpush(REDIS_LIST, json.dumps(payload))
        CONTACT_PUSHED.inc()
        logger.info("Queued: %s", payload)
        return {"status": "queued", "payload": payload}
    except Exception as e:
        logger.exception("Failed to queue message")
        raise HTTPException(status_code=500, detail="Failed to enqueue message")

@app.get("/health")
async def health():
    status = {"service": "fastapi", "status": "ok"}
    try:
        r = get_redis()
        r.ping()
        status["redis"] = "connected"
    except Exception as e:
        status["redis"] = "disconnected"
        status["error"] = str(e)
    return status

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=int(os.getenv("PORT","8000")), reload=False)
PY

  cat > "${APP_DIR}/worker.py" <<'PY'
#!/usr/bin/env python3
# app/worker.py - worker that BLPOP from Redis, publishes to Kafka and stores in Postgres
import os, json, time, logging
import redis
from kafka import KafkaProducer
import psycopg2

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("worker")

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_LIST = os.getenv("REDIS_LIST", "outgoing_messages")

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
KAFKA_TOPIC = os.getenv("KAFKA_TOPIC", "survey-topic")

DATABASE_URL = os.getenv("DATABASE_URL", "dbname=webdb user=webuser password=testpassword host=postgres-db")

def get_redis():
    return redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

def get_kafka():
    try:
        return KafkaProducer(bootstrap_servers=KAFKA_BOOTSTRAP.split(','), value_serializer=lambda v: json.dumps(v).encode('utf-8'))
    except Exception as e:
        logger.exception("Kafka init error: %s", e)
        return None

def save_to_db(email, message):
    conn = psycopg2.connect(DATABASE_URL)
    cur = conn.cursor()
    cur.execute("INSERT INTO contact_messages (email, message) VALUES (%s, %s)", (email, message))
    conn.commit()
    cur.close()
    conn.close()

def process_item(item, producer):
    try:
        if producer:
            producer.send(KAFKA_TOPIC, value=item)
            producer.flush()
        save_to_db(item.get("email"), item.get("message"))
        logger.info("Processed: %s", item.get("email"))
    except Exception:
        logger.exception("Processing failed")

def main():
    r = get_redis()
    producer = get_kafka()
    logger.info("Worker started. Listening on Redis list '%s'", REDIS_LIST)
    while True:
        try:
            res = r.blpop(REDIS_LIST, timeout=0)
            if res:
                _, data = res
                try:
                    item = json.loads(data)
                except Exception:
                    item = {"raw": data}
                process_item(item, producer)
        except Exception:
            logger.exception("Worker loop exception")
            time.sleep(2)

if __name__ == "__main__":
    main()
PY

  cat > "${TEMPLATES_DIR}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="pl">
  <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width,initial-scale=1"/>
    <title>Dawid Trojanowski - Kontakt</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
      body { font-family: system-ui, sans-serif; background: radial-gradient(circle at 10% 20%, #1e293b, #0f172a); color:#e6eef8; padding:24px; }
      .card { background: rgba(255,255,255,0.03); padding:20px; border-radius:12px; max-width:700px; margin:auto; }
      input, textarea { width:100%; padding:10px; margin-bottom:8px; border-radius:6px; border:1px solid rgba(255,255,255,0.08); background:rgba(255,255,255,0.02); color:white; }
      button { background:#7c3aed; color:white; padding:10px 14px; border-radius:8px; border:none; cursor:pointer; }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>Dawid Trojanowski — Kontakt</h1>
      <p>Wypełnij formularz, wiadomość trafi do kolejki Redis, worker zapisze do bazy i wyśle do Kafki.</p>
      <form id="contact-form">
        <input name="email" type="email" placeholder="Twój email" required/>
        <textarea name="message" rows="6" placeholder="Twoja wiadomość" required></textarea>
        <input name="id" placeholder="opcjonalne id"/>
        <button type="submit">Wyślij</button>
      </form>
      <div id="result" style="margin-top:12px;color:#c7f9cc"></div>
    </div>
    <script>
      const form = document.getElementById('contact-form');
      const result = document.getElementById('result');
      form.addEventListener('submit', async e => {
        e.preventDefault();
        const fd = new FormData(form);
        const r = await fetch('/api/contact', { method: 'POST', body: fd });
        const j = await r.json().catch(()=>({}));
        result.textContent = j.message || j.status || JSON.stringify(j);
        setTimeout(()=> result.textContent = '', 5000);
        form.reset();
      });
    </script>
  </body>
</html>
HTML

  cat > "${APP_DIR}/requirements.txt" <<'REQ'
fastapi==0.104.1
uvicorn==0.24.0
jinja2==3.1.2
psycopg2-binary==2.9.7
prometheus-fastapi-instrumentator==5.11.1
prometheus-client==0.16.0
python-multipart==0.0.6
pydantic==2.5.0
kafka-python==2.0.2
hvac==1.1.0
redis==4.6.0
REQ

  chmod +x "${APP_DIR}/worker.py"
  info "App files written."
}

# --------------------------------------------------
# Dockerfile
# --------------------------------------------------
generate_dockerfile(){
  info "Generating Dockerfile..."
  cat > "${ROOT_DIR}/Dockerfile" <<'DOCK'
# Dockerfile for FastAPI app + worker (single image for both)
FROM python:3.11-slim-bullseye

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ /app/

# expose app port
EXPOSE 8000

# default run the web app; worker runs via k8s command override
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
DOCK
  info "Dockerfile written."
}

# --------------------------------------------------
# GitHub Actions Workflow
# --------------------------------------------------
generate_github_actions(){
  info "Generating GitHub Actions workflow..."
  mkdir_p "$WORKFLOW_DIR"
  cat > "${WORKFLOW_DIR}/ci-cd.yaml" <<'YAML'
name: CI/CD - Build & Push

on:
  push:
    branches: [ main ]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.repository_owner }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          push: true
          tags: ${REGISTRY}:latest
YAML
  info "Workflow written."
}

# --------------------------------------------------
# Kubernetes manifests (full set)
# --------------------------------------------------
generate_k8s_manifests(){
  info "Generating Kubernetes manifests in ${BASE_DIR}..."
  mkdir_p "$BASE_DIR"

  # app deployment + service + sa
  cat > "${BASE_DIR}/app-deployment.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fastapi-web-app
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: fastapi
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${PROJECT}
      component: fastapi
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: fastapi
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "web-app-role"
        vault.hashicorp.com/agent-inject-secret-db-creds: "secret/data/database/postgres"
    spec:
      serviceAccountName: fastapi-sa
      containers:
      - name: app
        image: ${REGISTRY}:latest
        ports:
        - containerPort: 8000
        env:
        - name: REDIS_HOST
          value: "redis"
        - name: REDIS_PORT
          value: "6379"
        - name: REDIS_LIST
          value: "outgoing_messages"
        - name: KAFKA_BOOTSTRAP_SERVERS
          value: "kafka.${NAMESPACE}.svc.cluster.local:9092"
        - name: DATABASE_URL
          value: "dbname=webdb user=webuser password=testpassword host=postgres-db"
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 20
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: fastapi-web-service
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: fastapi
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8000
  selector:
    app: ${PROJECT}
    component: fastapi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fastapi-sa
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: fastapi
YAML

  # message processor (worker) deployment
  cat > "${BASE_DIR}/message-processor.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: message-processor
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: worker
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: worker
    spec:
      serviceAccountName: fastapi-sa
      containers:
      - name: worker
        image: ${REGISTRY}:latest
        command: ["python", "worker.py"]
        env:
        - name: REDIS_HOST
          value: "redis"
        - name: REDIS_PORT
          value: "6379"
        - name: REDIS_LIST
          value: "outgoing_messages"
        - name: KAFKA_BOOTSTRAP_SERVERS
          value: "kafka.${NAMESPACE}.svc.cluster.local:9092"
        - name: DATABASE_URL
          value: "dbname=webdb user=webuser password=testpassword host=postgres-db"
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
YAML

  # postgres statefulset + service
  cat > "${BASE_DIR}/postgres-db.yaml" <<YAML
apiVersion: v1
kind: Service
metadata:
  name: postgres-db
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: postgres
spec:
  ports:
    - port: 5432
      name: postgres
  selector:
    app: ${PROJECT}
    component: postgres
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-db
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: postgres
spec:
  serviceName: postgres-db
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: postgres
  template:
    metadata:
      labels:
        app: ${PROJECT}
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
          value: "testpassword"
        - name: POSTGRES_DB
          value: "webdb"
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
YAML

  # pgadmin
  cat > "${BASE_DIR}/pgadmin.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgadmin
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: pgadmin
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
        image: dpage/pgadmin4:latest
        env:
        - name: PGADMIN_DEFAULT_EMAIL
          value: "admin@webstack.local"
        - name: PGADMIN_DEFAULT_PASSWORD
          value: "adminpassword"
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin-service
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: pgadmin
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: pgadmin
YAML

  # vault (dev local demo)
  cat > "${BASE_DIR}/vault.yaml" <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-sa
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: vault
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: vault
spec:
  clusterIP: None
  ports:
  - name: http
    port: 8200
  selector:
    app: vault
    component: vault
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: vault
spec:
  serviceName: vault
  replicas: 1
  selector:
    matchLabels:
      app: vault
      component: vault
  template:
    metadata:
      labels:
        app: vault
        component: vault
    spec:
      serviceAccountName: vault-sa
      containers:
      - name: vault
        image: hashicorp/vault:1.15.0
        ports:
        - containerPort: 8200
        env:
        - name: VAULT_LOCAL_CONFIG
          value: |
            listener "tcp" { address = "0.0.0.0:8200" tls_disable = "true" }
            storage "file" { path = "/vault/file" }
            ui = true
        volumeMounts:
        - name: vault-data
          mountPath: /vault/file
  volumeClaimTemplates:
  - metadata:
      name: vault-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
YAML

  # redis + redis-insight (UI)
  cat > "${BASE_DIR}/redis.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ${NAMESPACE}
  labels:
    app: redis
    component: redis
spec:
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
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        command: ["redis-server","--appendonly","yes"]
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ${NAMESPACE}
spec:
  ports:
  - port: 6379
    targetPort: 6379
  selector:
    app: redis
YAML

  cat > "${BASE_DIR}/redis-insight.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-insight
  namespace: ${NAMESPACE}
  labels:
    app: redis-insight
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-insight
  template:
    metadata:
      labels:
        app: redis-insight
    spec:
      containers:
      - name: redis-insight
        image: redislabs/redisinsight:latest
        ports:
        - containerPort: 8001
---
apiVersion: v1
kind: Service
metadata:
  name: redis-insight
  namespace: ${NAMESPACE}
spec:
  ports:
  - port: 8001
    targetPort: 8001
  selector:
    app: redis-insight
YAML

  # kafka-kraft (single-node)
  cat > "${BASE_DIR}/kafka-kraft.yaml" <<YAML
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: ${NAMESPACE}
  labels:
    app: kafka
    component: kafka
spec:
  ports:
  - port: 9092
    name: client
  - port: 9093
    name: inter-broker
  selector:
    app: kafka
    component: kafka
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: ${NAMESPACE}
  labels:
    app: kafka
    component: kafka
spec:
  serviceName: kafka
  replicas: 1
  selector:
    matchLabels:
      app: kafka
      component: kafka
  template:
    metadata:
      labels:
        app: kafka
        component: kafka
    spec:
      containers:
      - name: kafka
        image: bitnami/kafka:3.6.1
        env:
        - name: KAFKA_CFG_NODE_ID
          value: "1"
        - name: KAFKA_CFG_PROCESS_ROLES
          value: "controller,broker"
        - name: KAFKA_CFG_CONTROLLER_QUORUM_VOTERS
          value: "1@kafka:9093"
        - name: KAFKA_CFG_LISTENERS
          value: "CLIENT://:9092,INTERNAL://:9093"
        - name: KAFKA_CFG_ADVERTISED_LISTENERS
          value: "CLIENT://kafka:9092,INTERNAL://kafka:9093"
        - name: KAFKA_CFG_KRAFT_CLUSTER_ID
          value: "${KAFKA_CLUSTER_ID}"
        ports:
        - containerPort: 9092
YAML

  # kafka-ui
  cat > "${BASE_DIR}/kafka-ui.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-ui
  namespace: ${NAMESPACE}
  labels:
    app: kafka-ui
    component: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kafka-ui
  template:
    metadata:
      labels:
        app: kafka-ui
    spec:
      containers:
      - name: kafka-ui
        image: provectuslabs/kafka-ui:latest
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-ui
  namespace: ${NAMESPACE}
spec:
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: kafka-ui
YAML

  # prometheus-config + prometheus
  cat > "${BASE_DIR}/prometheus-config.yaml" <<YAML
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
      - job_name: 'fastapi'
        static_configs:
          - targets: ['fastapi-web-service:80']
YAML

  cat > "${BASE_DIR}/prometheus.yaml" <<YAML
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
        image: prom/prometheus:v2.48.0
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
      volumes:
      - name: config
        configMap:
          name: prometheus-config
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-service
  namespace: ${NAMESPACE}
spec:
  ports:
  - port: 9090
    targetPort: 9090
  selector:
    app: prometheus
YAML

  # grafana-datasource + grafana
  cat > "${BASE_DIR}/grafana-datasource.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource
  namespace: ${NAMESPACE}
data:
  prometheus.yaml: |
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-service:9090
      isDefault: true
YAML

  cat > "${BASE_DIR}/grafana.yaml" <<YAML
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
        image: grafana/grafana:10.2.2
        env:
        - name: GF_SECURITY_ADMIN_USER
          value: admin
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: admin
        ports:
        - containerPort: 3000
---
apiVersion: v1
kind: Service
metadata:
  name: grafana-service
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 3000
  selector:
    app: grafana
YAML

  # loki-config + loki
  cat > "${BASE_DIR}/loki-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: ${NAMESPACE}
data:
  loki.yaml: |
    server:
      http_listen_port: 3100
YAML

  cat > "${BASE_DIR}/loki.yaml" <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  namespace: ${NAMESPACE}
spec:
  serviceName: loki
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
        image: grafana/loki:2.9.2
        ports:
        - containerPort: 3100
YAML

  # promtail-config + promtail
  cat > "${BASE_DIR}/promtail-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: ${NAMESPACE}
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
    clients:
      - url: http://loki:3100/loki/api/v1/push
YAML

  cat > "${BASE_DIR}/promtail.yaml" <<YAML
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
        image: grafana/promtail:2.9.2
YAML

  # tempo-config + tempo
  cat > "${BASE_DIR}/tempo-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: ${NAMESPACE}
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
YAML

  cat > "${BASE_DIR}/tempo.yaml" <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tempo
  namespace: ${NAMESPACE}
spec:
  serviceName: tempo
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
        image: grafana/tempo:2.4.2
        ports:
        - containerPort: 3200
YAML

  # ingress
  cat > "${BASE_DIR}/ingress.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${PROJECT}-ingress
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: "nginx"
spec:
  rules:
  - host: app.${PROJECT}.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: fastapi-web-service
            port:
              number: 80
YAML

  # kyverno policy
  cat > "${BASE_DIR}/kyverno-policy.yaml" <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-requests-limits
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: check-container-resources
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "All containers must define 'requests' and 'limits' for CPU and memory."
      foreach:
      - variables:
          element: "{{ request.object.spec.containers[] }}"
        deny:
          conditions:
            any:
            - key: "{{ element.resources.requests.cpu || '' }}"
              operator: Equals
              value: ""
            - key: "{{ element.resources.limits.cpu || '' }}"
              operator: Equals
              value: ""
YAML

  # kustomization with full resource list
  cat > "${BASE_DIR}/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NAMESPACE}

resources:
  - app-deployment.yaml
  - message-processor.yaml
  - postgres-db.yaml
  - pgadmin.yaml
  - vault.yaml
  - redis.yaml
  - redis-insight.yaml
  - kafka-kraft.yaml
  - kafka-ui.yaml
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
  app.kubernetes.io/name: ${PROJECT}
  app.kubernetes.io/instance: ${PROJECT}
  app.kubernetes.io/managed-by: kustomize
YAML

  # argocd application
  cat > "${ROOT_DIR}/argocd-application.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${PROJECT}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: HEAD
    path: manifests/base
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
YAML

  info "Kubernetes manifests generated."
}

# --------------------------------------------------
# README
# --------------------------------------------------
generate_readme(){
  info "Generating README.md..."
  cat > "${ROOT_DIR}/README.md" <<README
# ${PROJECT} - All-in-one teaching stack

This repository is a generated example for the lab exercise:
- Form -> Redis -> Worker -> Kafka + Postgres
- Monitoring: Prometheus / Grafana / Tempo / Loki / Promtail
- Secrets demo: Vault (dev mode) - DO NOT use in production
- Policy: Kyverno (example ClusterPolicy)
- UI: Kafka UI, RedisInsight, pgAdmin, Grafana

Quickstart (local minikube / cluster):
1. Build & push the container (or change manifests to use local image)
   docker build -t ${REGISTRY}:latest .
   docker push ${REGISTRY}:latest

2. Apply manifests:
   kubectl apply -k manifests/base

3. Test flow:
   - Submit: curl -F "email=test@x" -F "message=hello" http://<ingress or svc>/api/contact
   - Check Redis LRANGE outgoing_messages 0 -1
   - Check message-processor logs, Kafka UI, and Postgres entries

Security:
- Replace example passwords and Vault dev-mode with production secrets (K8s Secret, SealedSecrets or Vault with proper auth)
- Validate Kyverno policy and resource requests prior to production

README generated by unified-stack.sh
README
  info "README written."
}

# --------------------------------------------------
# Orchestrator
# --------------------------------------------------
generate_all(){
  info "Starting full generation..."
  generate_structure
  generate_fastapi_app
  generate_dockerfile
  generate_github_actions
  generate_k8s_manifests
  generate_readme
  echo
  info "✅ Generation complete. Files created under ${ROOT_DIR}"
  echo "Next steps: build/push image, then kubectl apply -k manifests/base"
}

# CLI
case "${1:-}" in
  generate) generate_all ;;
  help|-h|--help)
    cat <<EOF
Usage: $0 generate
Generates an all-in-one project scaffold (app, manifests, dockerfile, CI).
EOF
    ;;
  *)
    echo "Unknown command. Use: $0 help"
    exit 1
    ;;
esac