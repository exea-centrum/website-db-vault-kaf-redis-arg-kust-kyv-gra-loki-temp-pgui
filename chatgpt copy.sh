#!/usr/bin/env bash
set -euo pipefail

# Unified GitOps Stack Generator - FastAPI + Full Stack
# Generates complete application with ArgoCD, Vault, Postgres, Redis, Kafka (KRaft), Grafana, Prometheus, Loki, Tempo, Kyverno

# PROJECT NAME - short and readable
PROJECT="website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui"
NAMESPACE="${PROJECT}-ns"
ORG="exea-centrum"
REGISTRY="ghcr.io/${ORG}/${PROJECT}"
REPO_URL="https://github.com/${ORG}/${PROJECT}.git"
KAFKA_CLUSTER_ID="4mUj5vFk3tW7pY0iH2gR8qL6eD9oB1cZ" # Fixed ID for single-node KRaft

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
  mkdir_p "$APP_DIR/templates" "$BASE_DIR" "$WORKFLOW_DIR" "static"
}

# ==============================
# FASTAPI APPLICATION
# ==============================
generate_fastapi_app(){
  info "Generating FastAPI application with Kafka and Tracing..."
  
  # main.py
  cat << 'EOF' > "$APP_DIR/main.py"
from fastapi import FastAPI, Form, Request, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
import psycopg2
import os
import logging
from prometheus_fastapi_instrumentator import Instrumentator
from pydantic import BaseModel
from typing import List, Dict, Any
import time
import json

# Kafka imports
from kafka import KafkaProducer

# OpenTelemetry imports
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

app = FastAPI(title="Dawid Trojanowski - Personal Website")
templates = Jinja2Templates(directory="templates")
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

# CORS configuration
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

DB_CONN = os.getenv("DATABASE_URL", "dbname=webdb user=webuser password=webpass host=postgres-db")
KAFKA_SERVER = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://tempo:4317")
SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "webstack-app")

Instrumentator().instrument(app).expose(app)

# ========================================================
# 1. TRACING CONFIGURATION (OpenTelemetry for Tempo)
# ========================================================
resource = Resource.create(attributes={
    "service.name": SERVICE_NAME
})

trace.set_tracer_provider(
    TracerProvider(resource=resource)
)
tracer = trace.get_tracer(__name__)

# Configure export to Tempo (OTLP over gRPC)
otlp_exporter = OTLPSpanExporter(endpoint=OTEL_ENDPOINT)
span_processor = BatchSpanProcessor(otlp_exporter)
trace.get_tracer_provider().add_span_processor(span_processor)

# FastAPI instrumentation (automatic traces)
FastAPIInstrumentor.instrument_app(app, tracer_provider=trace.get_tracer_provider())

# ========================================================
# 2. KAFKA CONFIGURATION
# ========================================================
def get_kafka_producer():
    """Initialize Kafka producer."""
    try:
        producer = KafkaProducer(
            bootstrap_servers=KAFKA_SERVER.split(','),
            value_serializer=lambda v: json.dumps(v).encode('utf-8'),
            api_version=(0, 10, 1)
        )
        logger.info(f"Kafka Producer initialized for {KAFKA_SERVER}")
        return producer
    except Exception as e:
        logger.error(f"Failed to initialize Kafka Producer: {e}")
        return None

KAFKA_PRODUCER = get_kafka_producer()

class SurveyResponse(BaseModel):
    question: str
    answer: str

def get_db_connection():
    """Create database connection with retry logic"""
    max_retries = 30
    for attempt in range(max_retries):
        try:
            conn = psycopg2.connect(DB_CONN)
            return conn
        except psycopg2.OperationalError as e:
            logger.warning(f"Attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(10)
            else:
                logger.error(f"All connection attempts failed: {e}")
                raise e

def init_database():
    """Initialize database"""
    max_retries = 30
    for attempt in range(max_retries):
        try:
            conn = get_db_connection()
            cur = conn.cursor()
            
            # Survey responses table
            cur.execute("""
                CREATE TABLE IF NOT EXISTS survey_responses(
                    id SERIAL PRIMARY KEY,
                    question TEXT NOT NULL,
                    answer TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Page visits table
            cur.execute("""
                CREATE TABLE IF NOT EXISTS page_visits(
                    id SERIAL PRIMARY KEY,
                    page VARCHAR(255) NOT NULL,
                    visited_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Contact messages table
            cur.execute("""
                CREATE TABLE IF NOT EXISTS contact_messages(
                    id SERIAL PRIMARY KEY,
                    email VARCHAR(255) NOT NULL,
                    message TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            conn.commit()
            cur.close()
            conn.close()
            logger.info("Database initialized successfully")
            return
        except Exception as e:
            logger.warning(f"Database initialization attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(10)
            else:
                logger.error(f"All database initialization attempts failed: {e}")

@app.on_event("startup")
async def startup_event():
    init_database()

@app.on_event("shutdown")
async def shutdown_event():
    if KAFKA_PRODUCER:
        KAFKA_PRODUCER.close()
        logger.info("Kafka Producer closed.")

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    """Home page"""
    with tracer.start_as_current_span("db-log-visit"):
        try:
            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute("INSERT INTO page_visits (page) VALUES ('home')")
            conn.commit()
            cur.close()
            conn.close()
        except Exception as e:
            logger.error(f"Error logging page visit: {e}")
        
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        return {"status": "healthy", "database": "connected"}
    except Exception as e:
        logger.warning(f"Health check database connection failed: {e}")
        return {"status": "healthy", "database": "disconnected", "error": str(e)}

@app.get("/api/survey/questions")
async def get_survey_questions():
    """Get survey questions"""
    questions = [
        {
            "id": 1,
            "text": "How do you rate the website design?",
            "type": "rating",
            "options": ["1 - Poor", "2", "3", "4", "5 - Excellent"]
        },
        {
            "id": 2,
            "text": "Was the information helpful?",
            "type": "choice",
            "options": ["Yes", "Rather yes", "Don't know", "Rather no", "No"]
        }
    ]
    return questions

@app.post("/api/survey/submit")
async def submit_survey(response: SurveyResponse):
    """Save survey response and send to Kafka"""
    
    with tracer.start_as_current_span("save-to-postgres"):
        try:
            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO survey_responses (question, answer) VALUES (%s, %s)",
                (response.question, response.answer)
            )
            conn.commit()
            cur.close()
            conn.close()
            logger.info(f"Survey response saved to DB: {response.question} -> {response.answer}")
        except Exception as e:
            logger.error(f"Error saving survey response to DB: {e}")
            raise HTTPException(status_code=500, detail="Error saving response to DB")

    with tracer.start_as_current_span("send-to-kafka"):
        if KAFKA_PRODUCER:
            message = {
                "question": response.question,
                "answer": response.answer,
                "timestamp": time.time()
            }
            try:
                # Send message to topic
                KAFKA_PRODUCER.send('survey-topic', value=message)
                logger.info(f"Message sent to Kafka topic 'survey-topic'")
            except Exception as e:
                logger.error(f"Error sending message to Kafka: {e}")
                pass
        else:
            logger.warning("Kafka Producer is not initialized. Skipping message send.")

    return {"status": "success", "message": "Thank you for completing the survey! (Saved and sent to Kafka)"}

@app.get("/api/survey/stats")
async def get_survey_stats():
    """Get survey statistics"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        cur.execute("""
            SELECT question, answer, COUNT(*) as count 
            FROM survey_responses 
            GROUP BY question, answer 
            ORDER BY question, count DESC
        """)
        responses = cur.fetchall()
        
        cur.execute("SELECT COUNT(*) FROM page_visits")
        total_visits = cur.fetchone()[0]
        
        cur.close()
        conn.close()
        
        stats = {}
        for question, answer, count in responses:
            if question not in stats:
                stats[question] = []
            stats[question].append({"answer": answer, "count": count})
        
        return {
            "survey_responses": stats,
            "total_visits": total_visits,
            "total_responses": sum(len(answers) for answers in stats.values())
        }
    except Exception as e:
        logger.error(f"Error fetching survey stats: {e}")
        raise HTTPException(status_code=500, detail="Error fetching statistics")

@app.post("/api/contact")
async def submit_contact(email: str = Form(...), message: str = Form(...)):
    """Save contact message"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO contact_messages (email, message) VALUES (%s, %s)",
            (email, message)
        )
        conn.commit()
        cur.close()
        conn.close()
        logger.info(f"Contact message saved from: {email}")
        return {"status": "success", "message": "Message sent successfully!"}
    except Exception as e:
        logger.error(f"Error saving contact message: {e}")
        raise HTTPException(status_code=500, detail="Error sending message")

@app.get("/api/visits")
async def get_visit_stats():
    """Get visit statistics"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        cur.execute("""
            SELECT page, COUNT(*) as visits,
                   DATE(visited_at) as date
            FROM page_visits 
            GROUP BY page, DATE(visited_at)
            ORDER BY date DESC
        """)
        visits = cur.fetchall()
        
        cur.close()
        conn.close()
        
        return {
            "visits": [
                {
                    "page": page,
                    "visits": visit_count,
                    "date": date.isoformat() if date else None
                }
                for page, visit_count, date in visits
            ]
        }
    except Exception as e:
        logger.error(f"Error fetching visit stats: {e}")
        raise HTTPException(status_code=500, detail="Error fetching visit statistics")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
EOF

  # requirements.txt
  cat << 'EOF' > "$APP_DIR/requirements.txt"
fastapi==0.104.1
uvicorn==0.24.0
jinja2==3.1.2
psycopg2-binary==2.9.7
prometheus-fastapi-instrumentator==5.11.1
python-multipart==0.0.6
pydantic==2.5.0
kafka-python==2.0.2
opentelemetry-api==1.22.0
opentelemetry-sdk==1.22.0
opentelemetry-instrumentation-fastapi==0.43b0
opentelemetry-exporter-otlp==1.22.0
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
    <title>Dawid Trojanowski - Personal Website</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
</head>
<body class="bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900 text-white min-h-screen">
    <header class="border-b border-purple-500/30 backdrop-blur-sm bg-black/20 sticky top-0 z-50">
        <div class="container mx-auto px-6 py-4">
            <h1 class="text-3xl font-bold bg-gradient-to-r from-purple-400 to-pink-400 bg-clip-text text-transparent">
                Dawid Trojanowski
            </h1>
        </div>
    </header>
    <main class="container mx-auto px-6 py-12">
        <div class="bg-gradient-to-br from-purple-500/10 to-pink-500/10 backdrop-blur-lg border border-purple-500/20 rounded-2xl p-8">
            <h2 class="text-4xl font-bold mb-6 text-purple-300">About Me</h2>
            <p class="text-lg text-gray-300 leading-relaxed">
                Hello! I'm Dawid Trojanowski, passionate about IT and new technologies.
            </p>
        </div>
    </main>
    <footer class="border-t border-purple-500/30 backdrop-blur-sm bg-black/20 mt-16">
        <div class="container mx-auto px-6 py-8 text-center text-gray-400">
            <p>Dawid Trojanowski © 2025</p>
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
  cat << EOF > "${ROOT_DIR}/Dockerfile"
FROM python:3.11-slim-bullseye

WORKDIR /app

# Environment variables
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1

# Copy dependencies
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY ./app /app/app
COPY ./static /app/static
COPY ./templates /app/templates

# Start application
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
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
    branches:
      - main
    paths:
      - 'app/**'
      - 'Dockerfile'
      - 'requirements.txt'

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Login to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: \${{ github.repository_owner }}
          password: \${{ secrets.GHCR_PAT }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          push: true
          tags: $REGISTRY:latest
          cache-from: type=registry,ref=$REGISTRY:latest
          cache-to: type=inline
EOF
}

# ==============================
# KUBERNETES MANIFESTS
# ==============================

# 1. Main Application
generate_k8s_base(){
  info "Generating app-deployment.yaml..."
  cat << EOF > "$BASE_DIR/app-deployment.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fastapi-web-app
  labels:
    app: $PROJECT
    component: fastapi
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $PROJECT
      component: fastapi
  template:
    metadata:
      labels:
        app: $PROJECT
        component: fastapi
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "web-app-role"
        vault.hashicorp.com/agent-inject-status: "update"
        vault.hashicorp.com/secret-volume-path: "/vault/secrets"
        vault.hashicorp.com/agent-inject-secret-db-creds: "secret/data/database/postgres"
        vault.hashicorp.com/agent-inject-template-db-creds: |
          {{- with secret "secret/data/database/postgres" -}}
          export POSTGRES_USER="{{ .Data.data.postgres-user }}"
          export POSTGRES_PASSWORD="{{ .Data.data.postgres-password }}"
          export POSTGRES_HOST="{{ .Data.data.postgres-host }}"
          export POSTGRES_DB="{{ .Data.data.postgres-db }}"
          {{- end -}}
    spec:
      serviceAccountName: fastapi-sa
      initContainers:
      - name: wait-for-db
        image: postgres:15-alpine
        command: 
        - sh
        - -c
        - |
          until pg_isready -h postgres-db -p 5432 -U webuser -d webdb; do
            echo "Database not ready. Waiting..."
            sleep 5
          done
          echo "Database ready!"
        env:
        - name: PGPASSWORD
          value: "testpassword"
      containers:
      - name: app
        image: $REGISTRY:latest
        ports:
        - containerPort: 8000
        env:
          - name: VAULT_ADDR
            value: "http://vault:8200"
          - name: APP_NAME
            value: "$PROJECT"
          - name: KAFKA_BOOTSTRAP_SERVERS
            value: "kafka:9092"
          - name: OTEL_SERVICE_NAME
            value: "$PROJECT-fastapi"
          - name: OTEL_EXPORTER_OTLP_ENDPOINT
            value: "http://tempo:4317"
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
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
  labels:
    app: $PROJECT
    component: fastapi
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8000
    protocol: TCP
  selector:
    app: $PROJECT
    component: fastapi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fastapi-sa
  labels:
    app: $PROJECT
    component: fastapi
EOF
}

# 2. PostgreSQL Database
generate_postgres(){
  info "Generating postgres-db.yaml..."
  cat << EOF > "$BASE_DIR/postgres-db.yaml"
apiVersion: v1
kind: Service
metadata:
  name: postgres-db
  labels:
    app: $PROJECT
    component: postgres
spec:
  ports:
  - port: 5432
    name: postgres
  selector:
    app: $PROJECT
    component: postgres
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-db
  labels:
    app: $PROJECT
    component: postgres
spec:
  serviceName: "postgres-db"
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
            value: "testpassword"
          - name: POSTGRES_DB
            value: "webdb"
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
          subPath: postgres-data
        resources:
          requests:
            memory: "256Mi"
            cpu: "300m"
          limits:
            memory: "512Mi"
            cpu: "750m"
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
      name: postgres-storage
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi
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
      initContainers:
      - name: wait-for-db
        image: postgres:15-alpine
        command: 
        - sh
        - -c
        - |
          until pg_isready -h postgres-db -p 5432 -U webuser -d webdb; do
            sleep 5
          done
        env:
        - name: PGPASSWORD
          value: "testpassword"
      containers:
      - name: pgadmin
        image: dpage/pgadmin4:latest
        ports:
        - containerPort: 80
        env:
          - name: PGADMIN_DEFAULT_EMAIL
            value: "admin@webstack.local"
          - name: PGADMIN_DEFAULT_PASSWORD
            value: "adminpassword"
          - name: PGADMIN_LISTEN_PORT
            value: "80"
          - name: PGADMIN_LISTEN_ADDRESS
            value: "0.0.0.0"
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
  name: pgadmin-service
  labels:
    app: $PROJECT
    component: pgadmin
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
  selector:
    app: $PROJECT
    component: pgadmin
EOF
}

# 4. Vault
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
  clusterIP: None
  ports:
  - name: http
    port: 8200
  selector:
    app: $PROJECT
    component: vault
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault
  labels:
    app: $PROJECT
    component: vault
spec:
  serviceName: "vault"
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
        ports:
        - containerPort: 8200
        env:
          - name: VAULT_LOCAL_CONFIG
            value: |
              listener "tcp" {
                address = "0.0.0.0:8200"
                cluster_address = "0.0.0.0:8201"
                tls_disable = "true"
              }
              storage "file" {
                path = "/vault/file"
              }
              disable_mlock = true
              ui = true
        volumeMounts:
        - name: vault-storage
          mountPath: /vault/file
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1024Mi"
            cpu: "1000m"
  volumeClaimTemplates:
  - metadata:
      name: vault-storage
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 1Gi
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
  type: ClusterIP
  ports:
    - port: 6379
      targetPort: 6379
      protocol: TCP
  selector:
    app: $PROJECT
    component: redis
EOF
}

# 6. Kafka KRaft
generate_kafka(){
  info "Generating kafka-kraft.yaml..."
  cat << EOF > "$BASE_DIR/kafka-kraft.yaml"
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
    name: client
  - port: 9093
    name: inter-broker
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
        image: bitnami/kafka:3.6.1
        ports:
        - containerPort: 9092
          name: client
        - containerPort: 9093
          name: inter-broker
        env:
          - name: KAFKA_CFG_NODE_ID
            value: "1"
          - name: KAFKA_CFG_PROCESS_ROLES
            value: "controller,broker"
          - name: KAFKA_CFG_CONTROLLER_QUORUM_VOTERS
            value: "1@kafka:9093"
          - name: KAFKA_CFG_LISTENERS
            value: "CLIENT://:9092, INTERNAL://:9093"
          - name: KAFKA_CFG_ADVERTISED_LISTENERS
            value: "CLIENT://kafka:9092, INTERNAL://kafka:9093"
          - name: KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP
            value: "CLIENT:PLAINTEXT, INTERNAL:PLAINTEXT"
          - name: KAFKA_CFG_CONTROLLER_LISTENER_NAMES
            value: "INTERNAL"
          - name: KAFKA_CFG_KRAFT_CLUSTER_ID
            value: "${KAFKA_CLUSTER_ID}"
          - name: KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE
            value: "true"
        volumeMounts:
        - name: kafka-data
          mountPath: /bitnami/kafka/data
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1024Mi"
            cpu: "1000m"
  volumeClaimTemplates:
  - metadata:
      name: kafka-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi
EOF
}

# 7. Monitoring Stack
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
      evaluation_interval: 15s

    scrape_configs:
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:9090']

      - job_name: 'fastapi-app'
        metrics_path: /metrics
        static_configs:
          - targets: ['fastapi-web-service:80']
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
        image: prom/prometheus:v2.48.0
        args:
          - "--config.file=/etc/prometheus/prometheus.yml"
          - "--storage.tsdb.path=/prometheus"
          - "--web.enable-lifecycle"
        ports:
        - containerPort: 9090
        volumeMounts:
          - name: prometheus-config
            mountPath: /etc/prometheus
          - name: prometheus-storage
            mountPath: /prometheus
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
        - name: prometheus-config
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
  type: ClusterIP
  ports:
  - port: 9090
    targetPort: 9090
    protocol: TCP
  selector:
    app: $PROJECT
    component: prometheus
EOF
}

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
      isDefault: true
      access: proxy
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
        image: grafana/grafana:10.2.2
        ports:
        - containerPort: 3000
        env:
          - name: GF_SECURITY_ADMIN_USER
            value: admin
          - name: GF_SECURITY_ADMIN_PASSWORD
            value: admin
        volumeMounts:
          - name: grafana-datasource
            mountPath: /etc/grafana/provisioning/datasources
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
      volumes:
        - name: grafana-datasource
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
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 3000
    protocol: TCP
  selector:
    app: $PROJECT
    component: grafana
EOF
}

# 8. Logging Stack
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
      path_prefix: /loki/data
      replication_factor: 1
      ring:
        instance_addr: 127.0.0.1
        kvstore:
          store: inmemory
    schema_config:
      configs:
        - from: 2024-01-01
          store: boltdb-shipper
          object_store: filesystem
          schema: v12
          index:
            prefix: index_
            period: 24h
    storage_config:
      boltdb_shipper:
        active_index_directory: /loki/index
        cache_location: /loki/cache
        shared_store: filesystem
      filesystem:
        directory: /loki/chunks
EOF

  cat << EOF > "$BASE_DIR/loki.yaml"
apiVersion: v1
kind: Service
metadata:
  name: loki
  labels:
    app: $PROJECT
    component: loki
spec:
  ports:
    - name: http
      port: 3100
      targetPort: 3100
  selector:
    app: $PROJECT
    component: loki
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  labels:
    app: $PROJECT
    component: loki
spec:
  serviceName: "loki"
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
        image: grafana/loki:2.9.2
        args:
          - "-config.file=/etc/loki/loki.yaml"
        ports:
        - containerPort: 3100
          name: http
        volumeMounts:
        - name: config
          mountPath: /etc/loki
        - name: storage
          mountPath: /loki
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
  volumeClaimTemplates:
  - metadata:
      name: storage
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 5Gi
EOF
}

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
    - job_name: kubernetes-pods
      kubernetes_sd_configs:
        - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_component]
        regex: promtail
        action: drop
      - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_pod_name]
        regex: (.+);(.+)
        target_label: __path__
        replacement: /var/log/pods/\$1/\$2/*.log
EOF

  cat << EOF > "$BASE_DIR/promtail.yaml"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: promtail-sa
  labels:
    app: $PROJECT
    component: promtail
---
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
      serviceAccountName: promtail-sa
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      hostPID: true
      containers:
      - name: promtail
        image: grafana/promtail:2.9.2
        args:
          - "-config.file=/etc/promtail/promtail.yaml"
        volumeMounts:
          - name: config
            mountPath: /etc/promtail
          - name: run
            mountPath: /run/docker/
          - name: logs
            mountPath: /var/log/
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
        - name: run
          hostPath:
            path: /run/docker/
        - name: logs
          hostPath:
            path: /var/log/
EOF
}

# 9. Tracing Stack
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
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
    storage:
      trace:
        backend: local
        local:
          path: /var/tempo/traces
EOF

  cat << EOF > "$BASE_DIR/tempo.yaml"
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
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tempo
  labels:
    app: $PROJECT
    component: tempo
spec:
  serviceName: "tempo"
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
        image: grafana/tempo:2.4.2
        args:
          - "-config.file=/etc/tempo/tempo.yaml"
        ports:
        - containerPort: 3200
          name: http
        - containerPort: 4317
          name: otlp-grpc
        volumeMounts:
        - name: config
          mountPath: /etc/tempo
        - name: storage
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
  volumeClaimTemplates:
  - metadata:
      name: storage
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 5Gi
EOF
}

# 10. Ingress
generate_ingress(){
  info "Generating ingress.yaml..."
  cat << EOF > "$BASE_DIR/ingress.yaml"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $PROJECT-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    kubernetes.io/ingress.class: "nginx"
spec:
  rules:
  - host: app.$PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: fastapi-web-service
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
  - host: prometheus.$PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus-service
            port:
              number: 9090
EOF
}

# 11. Kyverno Policy
generate_kyverno(){
  info "Generating kyverno-policy.yaml..."
  cat << EOF > "$BASE_DIR/kyverno-policy.yaml"
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-requests-limits
  annotations:
    policies.kyverno.io/title: Require CPU and Memory Limits
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: medium
  labels:
    app: $PROJECT
    component: kyverno
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
            - key: "{{ element.resources.requests.memory || '' }}"
              operator: Equals
              value: ""
            - key: "{{ element.resources.limits.memory || '' }}"
              operator: Equals
              value: ""
EOF
}

# 12. Kustomization
generate_kustomization(){
  info "Generating kustomization.yaml..."
  cat << EOF > "$BASE_DIR/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $NAMESPACE

resources:
  - app-deployment.yaml
  - postgres-db.yaml
  - pgadmin.yaml
  - vault.yaml
  - redis.yaml
  - kafka-kraft.yaml
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

# 13. ArgoCD Application
generate_argocd_app(){
  info "Generating argocd-application.yaml..."
  cat << EOF > "${ROOT_DIR}/argocd-application.yaml"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $PROJECT
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: HEAD
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
    retry:
      limit: 5
      backoff:
        duration: 5s
        maxDuration: 3m0s
        factor: 2
EOF
}

# 14. README
generate_readme(){
  info "Generating README.md..."
  cat << EOF > "${ROOT_DIR}/README.md"
# 🚀 $PROJECT - Unified GitOps Stack

Complete modern microservices architecture deployed using **GitOps (ArgoCD + Kustomize)**.

## 🛠️ Technology Stack

- **Application:** FastAPI (Python) with Kafka and OpenTelemetry Tracing
- **Registry:** GitHub Container Registry (ghcr.io)
- **CI/CD:** GitHub Actions (Build & Push Docker Image)
- **GitOps:** ArgoCD & Kustomize
- **Database:** PostgreSQL (StatefulSet)
- **DB Management:** pgAdmin
- **Cache/Broker:** Redis
- **Message Broker:** Apache Kafka (KRaft, Single-Node)
- **Secrets Management:** HashiCorp Vault
- **Monitoring & Observability:**
    - **Metrics:** Prometheus
    - **Logs:** Loki + Promtail
    - **Tracing:** Tempo (OpenTelemetry/OTLP)
    - **Visualization:** Grafana
- **Policy Management:** Kyverno

## 🚀 Quick Start

1. **Generate the project:**
   \`\`\`bash
   chmod +x unified-stack.sh
   ./unified-stack.sh generate
   \`\`\`

2. **Initialize Git and push:**
   \`\`\`bash
   git init
   git add .
   git commit -m 'Initial commit - unified stack with Kafka and Tempo tracing'
   git branch -M main
   git remote add origin $REPO_URL
   git push -u origin main
   \`\`\`

3. **Deploy with ArgoCD:**
   \`\`\`bash
   kubectl apply -f argocd-application.yaml
   \`\`\`

## 🌐 Access URLs

Add to your \`/etc/hosts\`:
\`\`\`
127.0.0.1 app.$PROJECT.local
127.0.0.1 pgadmin.$PROJECT.local
127.0.0.1 grafana.$PROJECT.local
127.0.0.1 prometheus.$PROJECT.local
\`\`\`

- **App:** http://app.$PROJECT.local
- **pgAdmin:** http://pgadmin.$PROJECT.local (admin@webstack.local / adminpassword)
- **Grafana:** http://grafana.$PROJECT.local (admin / admin)
- **Prometheus:** http://prometheus.$PROJECT.local

## 📊 Features

- FastAPI application with Kafka integration
- Distributed tracing with Tempo
- Comprehensive monitoring with Prometheus/Grafana
- Centralized logging with Loki
- GitOps deployment with ArgoCD
- Security policies with Kyverno

## 🏗️ Architecture

\`\`\`
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   FastAPI App   │───▶│     Kafka       │───▶│   PostgreSQL    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                      │                      │
         ▼                      ▼                      ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Tempo         │    │   Redis         │    │   pgAdmin       │
│   (Tracing)     │    │   (Cache)       │    │   (DB UI)       │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                      │                      │
         ▼                      ▼                      ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Loki          │    │   Prometheus    │    │   Grafana       │
│   (Logs)        │    │   (Metrics)     │    │   (Dashboard)   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                      │                      │
         ▼                      ▼                      ▼
┌─────────────────────────────────────────────────────────────┐
│                   ArgoCD (GitOps)                           │
└─────────────────────────────────────────────────────────────┘
\`\`\`
EOF
}

# ==============================
# MAIN FUNCTION
# ==============================
generate_all(){
  info "🚀 Starting unified stack generation..."
  
  generate_structure
  generate_fastapi_app
  generate_html_template
  generate_dockerfile
  generate_github_actions

  # Kubernetes Manifests
  generate_k8s_base
  generate_postgres
  generate_pgadmin
  generate_vault
  generate_redis
  generate_kafka
  generate_prometheus
  generate_grafana
  generate_loki
  generate_promtail
  generate_tempo
  generate_ingress
  generate_kyverno

  # GitOps
  generate_kustomization
  generate_argocd_app
  generate_readme
  
  echo ""
  info "✅ ALL DONE! Project name: $PROJECT"
  echo ""
  echo "📦 Generated:"
  echo "   ✓ FastAPI application in app/ (Kafka Producer, OTLP Tracing)"
  echo "   ✓ Dockerfile"
  echo "   ✓ GitHub Actions workflow"
  echo "   ✓ Kubernetes manifests in manifests/base/"
  echo "   ✓ argocd-application.yaml"
  echo "   ✓ README.md"
  echo ""
  echo "🚀 Next steps:"
  echo "1. Initialize Git and push to repository"
  echo "2. Deploy ArgoCD Application: kubectl apply -f argocd-application.yaml"
  echo "3. Check status: kubectl get applications -n argocd"
  echo ""
  echo "⚠️  IMPORTANT: Ensure that:"
  echo "   ✓ Repository $REPO_URL exists"
  echo "   ✓ ArgoCD is installed (kubectl get ns argocd)"
  echo "   ✓ manifests/base/ folder contains all files"
  echo ""
}

# ==============================
# MENU
# ==============================
case "${1:-}" in
  generate)
    generate_all
    ;;
  help|-h|--help)
    echo "Unified GitOps Stack Generator"
    echo ""
    echo "Usage: $0 generate"
    echo ""
    echo "Generates complete application with full DevOps stack"
    ;;
  *)
    echo "Unknown command. Use: $0 help"
    ;;
esac