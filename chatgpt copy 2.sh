#!/usr/bin/env bash
set -euo pipefail

# Unified deployment script - combines website app with full GitOps stack
# Generates FastAPI app + Kubernetes manifests with ArgoCD, Vault, Postgres, Redis, Kafka (KRaft), Grafana, Prometheus, Loki, Tempo, Kyverno, Adminer

# KRÓTSZA NAZWA PROJEKTU (NAPRAWA BŁĘDU INGRESS)
PROJECT="webstack-gitops" 
NAMESPACE="davtrowebdbvault"
ORG="exea-centrum"
REGISTRY="ghcr.io/${ORG}/${PROJECT}"
REPO_URL="https://github.com/${ORG}/${PROJECT}.git" 
KAFKA_CLUSTER_ID="4mUj5vFk3tW7pY0iH2gR8qL6eD9oB1cZ" # Stały ID dla jedno-węzłowego KRaft

ROOT_DIR="$(pwd)"
APP_DIR="app"
MANIFESTS_DIR="${ROOT_DIR}/manifests"
BASE_DIR="${MANIFESTS_DIR}/base"
WORKFLOW_DIR="${ROOT_DIR}/.github/workflows"

info(){ echo -e "🔧 [unified] $*"; }
mkdir_p(){ mkdir -p "$@"; }

# ==============================
# STRUKTURA KATALOGÓW
# ==============================
generate_structure(){
  info "Tworzenie struktury katalogów..."
  mkdir_p "$APP_DIR/templates" "$BASE_DIR" "$WORKFLOW_DIR"
}

# ==============================
# FASTAPI APLIKACJA
# (Kod logiki bez zmian)
# ==============================
generate_fastapi_app(){
  info "Generowanie FastAPI aplikacji z Kafka i Tracingiem..."
  
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

# Wymagane importy dla Kafka
from kafka import KafkaProducer

# Wymagane importy dla OpenTelemetry
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter


app = FastAPI(title="Dawid Trojanowski - Strona Osobista")
templates = Jinja2Templates(directory="templates")
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

# Konfiguracja CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

DB_CONN = os.getenv("DATABASE_URL", "dbname=appdb user=appuser password=apppass host=postgres")
KAFKA_SERVER = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://tempo:4317")
SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "website-app")


Instrumentator().instrument(app).expose(app)

# ========================================================
# 1. KONFIGURACJA TRACINGU (OpenTelemetry dla Tempo)
# ========================================================

resource = Resource.create(attributes={
    "service.name": SERVICE_NAME
})

trace.set_tracer_provider(
    TracerProvider(resource=resource)
)
tracer = trace.get_tracer(__name__)

# Konfiguracja eksportu do Tempo (OTLP over gRPC)
otlp_exporter = OTLPSpanExporter(endpoint=OTEL_ENDPOINT)
span_processor = BatchSpanProcessor(otlp_exporter)
trace.get_tracer_provider().add_span_processor(span_processor)

# Instrumentacja FastAPI (automatyczne ślady)
FastAPIInstrumentor.instrument_app(app, tracer_provider=trace.get_tracer_provider())


# ========================================================
# 2. KONFIGURACJA KAFKA
# ========================================================

def get_kafka_producer():
    """Inicjalizacja producenta Kafka."""
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
    """Utwórz połączenie z bazą danych z retry logic"""
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
    """Inicjalizacja bazy danych"""
    max_retries = 30
    for attempt in range(max_retries):
        try:
            conn = get_db_connection()
            cur = conn.cursor()
            
            # Tabela odpowiedzi ankiet
            cur.execute("""
                CREATE TABLE IF NOT EXISTS survey_responses(
                    id SERIAL PRIMARY KEY,
                    question TEXT NOT NULL,
                    answer TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Tabela odwiedzin stron
            cur.execute("""
                CREATE TABLE IF NOT EXISTS page_visits(
                    id SERIAL PRIMARY KEY,
                    page VARCHAR(255) NOT NULL,
                    visited_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Tabela kontaktów
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
    """Główna strona osobista"""
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
    """Pobiera listę pytań do ankiety"""
    questions = [
        {
            "id": 1,
            "text": "Jak oceniasz design strony?",
            "type": "rating",
            "options": ["1 - Słabo", "2", "3", "4", "5 - Doskonale"]
        },
        {
            "id": 2,
            "text": "Czy informacje były przydatne?",
            "type": "choice",
            "options": ["Tak", "Raczej tak", "Nie wiem", "Raczej nie", "Nie"]
        },
        {
            "id": 3,
            "text": "Jakie technologie Cię zainteresowaƂy?",
            "type": "multiselect",
            "options": ["Python", "JavaScript", "React", "Kubernetes", "Docker", "PostgreSQL"]
        },
        {
            "id": 4,
            "text": "Czy poleciłbyś tę stronę innym?",
            "type": "choice",
            "options": ["Zdecydowanie tak", "Prawdopodobnie tak", "Nie wiem", "Raczej nie", "Zdecydowanie nie"]
        },
        {
            "id": 5,
            "text": "Co sądzisz o portfolio?",
            "type": "text",
            "placeholder": "Podziel się swoją opinią..."
        }
    ]
    return questions

@app.post("/api/survey/submit")
async def submit_survey(response: SurveyResponse):
    """Zapisuje odpowiedź z ankiety i wysyła do Kafka"""
    
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
            raise HTTPException(status_code=500, detail="Błąd podczas zapisywania odpowiedzi w DB")

    with tracer.start_as_current_span("send-to-kafka"):
        if KAFKA_PRODUCER:
            message = {
                "question": response.question,
                "answer": response.answer,
                "timestamp": time.time()
            }
            try:
                # Wysłanie wiadomości do topicu
                KAFKA_PRODUCER.send('survey-topic', value=message)
                logger.info(f"Message sent to Kafka topic 'survey-topic'")
            except Exception as e:
                logger.error(f"Error sending message to Kafka: {e}")
                pass
        else:
            logger.warning("Kafka Producer is not initialized. Skipping message send.")


    return {"status": "success", "message": "Dziękujemy za wypełnienie ankiety! (Zapisano i wysłano do Kafka)"}

@app.get("/api/survey/stats")
async def get_survey_stats():
    # ... (Statystyki bez zmian)
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
        raise HTTPException(status_code=500, detail="Błąd podczas pobierania statystyk")

@app.post("/api/contact")
async def submit_contact(email: str = Form(...), message: str = Form(...)):
    """Zapisuje wiadomość kontaktową"""
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
        return {"status": "success", "message": "Wiadomość została wysłana!"}
    except Exception as e:
        logger.error(f"Error saving contact message: {e}")
        raise HTTPException(status_code=500, detail="Błąd podczas wysyłania wiadomości")

@app.get("/api/visits")
async def get_visit_stats():
    """Pobiera statystyki odwiedzin"""
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
        raise HTTPException(status_code=500, detail="Błąd podczas pobierania statystyk odwiedzin")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
EOF

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

# ==============================
# HTML TEMPLATE
# ==============================
generate_html_template(){
  info "Generowanie szablonu HTML..."
  cat << 'HTMLEOF' > "$APP_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dawid Trojanowski - Strona Osobista</title>
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
            <h2 class="text-4xl font-bold mb-6 text-purple-300">O Mnie</h2>
            <p class="text-lg text-gray-300 leading-relaxed">
                Cześć! Jestem Dawidem Trojanowskim, pasjonatem informatyki i nowych technologii.
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
  info "Generowanie Dockerfile..."
  cat << 'EOF' > "${ROOT_DIR}/Dockerfile"
FROM python:3.10-slim

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

ENV PYTHONUNBUFFERED=1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF
}

# ==============================
# GITHUB ACTIONS
# ==============================
generate_github_actions(){
  info "Generowanie GitHub Actions workflow..."
  cat > "${WORKFLOW_DIR}/ci.yml" <<GHA
name: CI/CD Build & Deploy

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
          username: \${{ github.actor }}
          password: \${{ secrets.GHCR_PAT }}
      
      - name: Build and push image
        uses: docker/build-push-action@v4
        with:
          context: .
          push: true
          tags: |
            ${REGISTRY}:latest
            ${REGISTRY}:\${{ github.sha }}
          cache-from: type=registry,ref=${REGISTRY}:latest
          cache-to: type=inline
GHA
}

# ==============================
# KUBERNETES MANIFESTS (BASE)
# ==============================
generate_k8s_base(){
  info "Generowanie podstawowych manifestów Kubernetes..."
  
  # ConfigMap
  cat > "${BASE_DIR}/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PROJECT}-config
  namespace: ${NAMESPACE}
data:
  DATABASE_URL: "dbname=appdb user=appuser password=apppass host=postgres"
EOF

  # Secret
  cat > "${BASE_DIR}/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  postgres-password: "apppass"
  username: "appuser"
  password: "apppass"
EOF

  # Service Account
  cat > "${BASE_DIR}/service-account.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${PROJECT}
  namespace: ${NAMESPACE}
imagePullSecrets:
  - name: ghcr-pull-secret
EOF

  # App Deployment (Ujednolicono etykiety)
  cat > "${BASE_DIR}/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PROJECT}
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    environment: development
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${PROJECT}
  template:
    metadata:
      labels:
        app: ${PROJECT}
        environment: development # KLUCZOWE DLA KYVERNO
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: ${PROJECT}
      initContainers:
      - name: wait-for-db
        image: postgres:14
        command: 
        - sh
        - -c
        - |
          echo "Waiting for database..."
          until pg_isready -h postgres -p 5432 -U appuser -d appdb; do
            echo "Database not ready. Waiting..."
            sleep 5
          done
          echo "Database ready!"
        env:
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: postgres-password
      containers:
      - name: app
        image: ${REGISTRY}:latest
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          valueFrom:
            configMapKeyRef:
              name: ${PROJECT}-config
              key: DATABASE_URL
        # KONFIGURACJA KAFKA (KRaft)
        - name: KAFKA_BOOTSTRAP_SERVERS
          value: kafka:9092
        # KONFIGURACJA TRACINGU DLA TEMPO (OTLP)
        - name: OTEL_SERVICE_NAME
          value: ${PROJECT}-fastapi
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: http://tempo:4317
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: grpc
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 90
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 60
          periodSeconds: 5
EOF

  # Service
  cat > "${BASE_DIR}/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${PROJECT}
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    environment: development
spec:
  selector:
    app: ${PROJECT}
  ports:
    - port: 80
      targetPort: 8000
      protocol: TCP
  type: ClusterIP
EOF

  # Ingress (NAPRAWA BŁĘDU DŁUGIEJ NAZWY I DODANO ADMINER)
  cat > "${BASE_DIR}/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${PROJECT}
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
  labels: 
    app: ${PROJECT}
    environment: development
spec:
  rules:
  - host: app.${PROJECT}.local 
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${PROJECT}
            port:
              number: 80
  - host: pgadmin.${PROJECT}.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pgadmin
            port:
              number: 80
  - host: grafana.${PROJECT}.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 3000
  - host: adminer.${PROJECT}.local # DODANO ADMINER
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: adminer
            port:
              number: 8080
EOF
}

# ==============================
# POSTGRES (Ujednolicono etykiety)
# ==============================
generate_postgres(){
  info "Generowanie PostgreSQL..."
  cat > "${BASE_DIR}/postgres.yaml" <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: ${NAMESPACE}
  labels:
    app: postgres
    environment: development
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
        environment: development # KLUCZOWE DLA KYVERNO
    spec:
      containers:
      - name: postgres
        image: postgres:14
        env:
        - name: POSTGRES_DB
          value: appdb
        - name: POSTGRES_USER
          value: appuser
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: postgres-password
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        livenessProbe:
          exec:
            command:
            - sh
            - -c
            - exec pg_isready -U appuser -d appdb -h 127.0.0.1
          initialDelaySeconds: 30
          periodSeconds: 10
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: ${NAMESPACE}
  labels:
    app: postgres
    environment: development
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
EOF
}

# ==============================
# PGADMIN (Ujednolicono etykiety)
# ==============================
generate_pgadmin(){
  info "Generowanie pgAdmin..."
  cat > "${BASE_DIR}/pgadmin.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgadmin
  namespace: ${NAMESPACE}
  labels:
    app: pgadmin
    environment: development
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgadmin
  template:
    metadata:
      labels:
        app: pgadmin
        environment: development # KLUCZOWE DLA KYVERNO
    spec:
      initContainers:
      - name: wait-for-db
        image: postgres:14
        command: 
        - sh
        - -c
        - |
          until pg_isready -h postgres -p 5432 -U appuser -d appdb; do
            sleep 5
          done
        env:
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: postgres-password
      containers:
      - name: pgadmin
        image: dpage/pgadmin4:latest
        env:
        - name: PGADMIN_DEFAULT_EMAIL
          value: "admin@admin.com"
        - name: PGADMIN_DEFAULT_PASSWORD
          value: "admin"
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin
  namespace: ${NAMESPACE}
  labels:
    app: pgadmin
    environment: development
spec:
  selector:
    app: pgadmin
  ports:
  - port: 80
    targetPort: 80
EOF
}

# ==============================
# ADMINER (NOWOŚĆ: Dodany na życzenie)
# ==============================
generate_adminer(){
  info "Generowanie Adminer..."
  cat > "${BASE_DIR}/adminer.yaml" <<AD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: adminer
  namespace: ${NAMESPACE}
  labels:
    app: adminer
    environment: development
spec:
  replicas: 1
  selector:
    matchLabels:
      app: adminer
  template:
    metadata:
      labels:
        app: adminer
        environment: development
    spec:
      initContainers:
      - name: wait-for-db
        image: postgres:14
        command: 
        - sh
        - -c
        - |
          until pg_isready -h postgres -p 5432 -U appuser -d appdb; do
            sleep 5
          done
        env:
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: postgres-password
      containers:
      - name: adminer
        image: adminer:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: adminer
  namespace: ${NAMESPACE}
  labels:
    app: adminer
    environment: development
spec:
  selector:
    app: adminer
  ports:
  - port: 8080
    targetPort: 8080
AD
}


# ==============================
# VAULT (OSTATECZNA POPRAWKA: InitContainer dla read-only config)
# ==============================
generate_vault(){
  info "Generowanie Vault (Poprawiono błąd Read-only file system)..."
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
    disable_mlock = "true" 
VC

  cat > "${BASE_DIR}/vault-deployment.yaml" <<VD
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault
  namespace: ${NAMESPACE}
  labels:
    app: vault
    environment: development
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
        environment: development
    spec:
      initContainers:
      - name: copy-config
        image: busybox:1.36.1 
        command: ['sh', '-c', 'cp /tmp/config/vault.hcl /vault/config/']
        volumeMounts:
        - name: vault-config-cm       # Źródło: ConfigMap (Read-only)
          mountPath: /tmp/config
        - name: vault-config-writable # Cel: EmptyDir (Writable)
          mountPath: /vault/config
      containers:
      - name: vault
        image: hashicorp/vault:1.15.3
        args: ["server","-config=/vault/config/vault.hcl"]
        ports:
        - containerPort: 8200
        securityContext: # Dodano IPC_LOCK na wypadek, gdyby Vault nie zignorował mlock
          capabilities:
            add: ["IPC_LOCK"]
        volumeMounts:
        - name: vault-config-writable # Montujemy writable EmptyDir
          mountPath: /vault/config
        - name: vault-data
          mountPath: /vault/data
      volumes:
      - name: vault-config-cm # ConfigMap montowany tylko do InitContainera
        configMap:
          name: vault-config
      - name: vault-config-writable # Writable volume dla configu
        emptyDir: {}
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
  labels:
    app: vault
    environment: development
spec:
  ports:
  - port: 8200
  selector:
    app: vault
VD
}

# ==============================
# REDIS (Ujednolicono etykiety)
# ==============================
generate_redis(){
  info "Generowanie Redis..."
  cat > "${BASE_DIR}/redis.yaml" <<R
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
  namespace: ${NAMESPACE}
  labels:
    app: redis
    environment: development
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
        environment: development # KLUCZOWE DLA KYVERNO
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
  labels:
    app: redis
    environment: development
spec:
  ports:
  - port: 6379
  selector:
    app: redis
R
}

# ==============================
# KAFKA (Wdrożenie Kafka KRaft - bez Zookeepera)
# ==============================
generate_kafka(){
  info "Generowanie Kafka KRaft (bez Zookeepera)..."
  
  cat > "${BASE_DIR}/kafka.yaml" <<KAF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: ${NAMESPACE}
  labels:
    app: kafka
    environment: development
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
        environment: development # KLUCZOWE DLA KYVERNO
    spec:
      containers:
      - name: kafka
        image: apache/kafka:3.7.0 
        env:
        # 1. Konfiguracja KRaft
        - name: KAFKA_CFG_NODE_ID
          value: "1"
        - name: KAFKA_CFG_PROCESS_ROLES
          value: "controller,broker"
        - name: KAFKA_CFG_CONTROLLER_QUORUM_VOTERS
          value: "1@kafka:9093"
        - name: KAFKA_CFG_CONTROLLER_LISTENER_NAMES
          value: "CONTROLLER"
        - name: KAFKA_CFG_CLUSTER_ID
          value: "${KAFKA_CLUSTER_ID}"
        # 2. Konfiguracja Listanerów
        - name: KAFKA_CFG_LISTENERS
          value: "PLAINTEXT://:9092,CONTROLLER://:9093"
        - name: KAFKA_CFG_ADVERTISED_LISTENERS
          value: "PLAINTEXT://kafka:9092"
        - name: KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP
          value: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
        - name: KAFKA_CFG_LOG_DIRS
          value: "/tmp/kraft-storage"
        ports:
        - containerPort: 9092
        - containerPort: 9093 # Kontroler
        volumeMounts:
        - name: kafka-data
          mountPath: /tmp/kraft-storage
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
  labels:
    app: kafka
    environment: development
spec:
  ports:
  - port: 9092
    targetPort: 9092
    name: plaintext
  - port: 9093
    targetPort: 9093
    name: controller
  selector:
    app: kafka
KAF
}

# ==============================
# PROMETHEUS (Ujednolicono etykiety)
# ==============================
generate_prometheus(){
  info "Generowanie Prometheus..."
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
      - job_name: 'fastapi'
        metrics_path: /metrics
        static_configs:
          - targets: ['${PROJECT}:8000'] 
PC

  cat > "${BASE_DIR}/prometheus-deployment.yaml" <<PD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: ${NAMESPACE}
  labels:
    app: prometheus
    environment: development
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
        environment: development # KLUCZOWE DLA KYVERNO
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        args: ["--config.file=/etc/prometheus/prometheus.yml"]
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
  name: prometheus
  namespace: ${NAMESPACE}
  labels:
    app: prometheus
    environment: development
spec:
  ports:
  - port: 9090
  selector:
    app: prometheus
PD
}

# ==============================
# GRAFANA (Ujednolicono etykiety)
# ==============================
generate_grafana(){
  info "Generowanie Grafana..."
  cat > "${BASE_DIR}/grafana-secret.yaml" <<GS
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  admin-user: admin
  admin-password: admin
GS

  cat > "${BASE_DIR}/grafana-deployment.yaml" <<GD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: ${NAMESPACE}
  labels:
    app: grafana
    environment: development
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
        environment: development # KLUCZOWE DLA KYVERNO
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:latest
        ports:
        - containerPort: 3000
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
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: ${NAMESPACE}
  labels:
    app: grafana
    environment: development
spec:
  ports:
  - port: 3000
  selector:
    app: grafana
GD
}

# ==============================
# LOKI (Ujednolicono etykiety)
# ==============================
generate_loki(){
  info "Generowanie Loki..."
  cat > "${BASE_DIR}/loki-config.yaml" <<LKC
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: ${NAMESPACE}
data:
  loki.yaml: |
    auth_enabled: false
    server:
      http_listen_port: 3100
    common:
      path_prefix: /tmp/loki
      storage:
        filesystem:
          chunks_directory: /tmp/loki/chunks
          rules_directory: /tmp/loki/rules
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
LKC

  cat > "${BASE_DIR}/loki-deployment.yaml" <<LKD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: ${NAMESPACE}
  labels:
    app: loki
    environment: development
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
        environment: development # KLUCZOWE DLA KYVERNO
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
      volumes:
      - name: config
        configMap:
          name: loki-config
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: ${NAMESPACE}
  labels:
    app: loki
    environment: development
spec:
  ports:
  - port: 3100
  selector:
    app: loki
LKD
}

# ==============================
# PROMTAIL (Ujednolicono etykiety)
# ==============================
generate_promtail(){
  info "Generowanie Promtail..."
  cat > "${BASE_DIR}/promtail-config.yaml" <<PTC
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: ${NAMESPACE}
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
PTC

  cat > "${BASE_DIR}/promtail-deployment.yaml" <<PTD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: promtail
  namespace: ${NAMESPACE}
  labels:
    app: promtail
    environment: development
spec:
  replicas: 1
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
        environment: development # KLUCZOWE DLA KYVERNO
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
      volumes:
      - name: config
        configMap:
          name: promtail-config
      - name: varlog
        hostPath:
          path: /var/log
PTD
}

# ==============================
# TEMPO (Ujednolicono etykiety)
# ==============================
generate_tempo(){
  info "Generowanie Tempo..."
  cat > "${BASE_DIR}/tempo-config.yaml" <<TC
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: ${NAMESPACE}
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
TC

  cat > "${BASE_DIR}/tempo-deployment.yaml" <<TD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  namespace: ${NAMESPACE}
  labels:
    app: tempo
    environment: development
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tempo
  template:
    metadata:
      labels:
        app: tempo
        environment: development # KLUCZOWE DLA KYVERNO
    spec:
      containers:
      - name: tempo
        image: grafana/tempo:2.5.0
        args:
          - -config.file=/etc/tempo/tempo.yaml
        ports:
        - containerPort: 3200
        - containerPort: 4317 # OTLP gRPC
        - containerPort: 4318 # OTLP HTTP
        volumeMounts:
        - name: config
          mountPath: /etc/tempo
        - name: data
          mountPath: /var/tempo
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
  namespace: ${NAMESPACE}
  labels:
    app: tempo
    environment: development
spec:
  ports:
  - name: tempo-http
    port: 3200
    targetPort: 3200
  - name: otlp-grpc
    port: 4317 
    targetPort: 4317
  - name: otlp-http
    port: 4318 
    targetPort: 4318
  selector:
    app: tempo
TD
}

# ==============================
# KYVERNO POLICY (Wymaga etykiety 'environment')
# ==============================
generate_kyverno(){
  info "Generowanie Kyverno Policy..."
  cat > "${BASE_DIR}/kyverno-policy.yaml" <<KY
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: enforce
  rules:
  - name: check-for-labels
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Labels 'app' and 'environment' are required."
      pattern:
        metadata:
          labels:
            app: "?*"
            environment: "?*"
KY
}

# ==============================
# ARGOCD APPLICATION (Używa nowej, krótszej nazwy PROJECT)
# ==============================
generate_argocd_app(){
  info "Generowanie ArgoCD Application..."
  cat > "${BASE_DIR}/argocd-app.yaml" <<'AA'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: webstack-gitops
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/exea-centrum/webstack-gitops.git # UŻYWA NOWEJ NAZWY REPO!
    targetRevision: HEAD
    path: manifests/base
  destination:
    server: https://kubernetes.default.svc
    namespace: davtrowebdbvault
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
AA
}

# ==============================
# STANDALONE ARGOCD APP (do apply z CLI)
# ==============================
generate_argocd_standalone(){
  info "Generowanie standalone ArgoCD Application (poza kustomization)..."
  cat > "${ROOT_DIR}/argocd-application.yaml" <<'STANDALONE'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: webstack-gitops
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/exea-centrum/webstack-gitops.git # UŻYWA NOWEJ NAZWY REPO!
    targetRevision: HEAD
    path: manifests/base
  destination:
    server: https://kubernetes.default.svc
    namespace: davtrowebdbvault
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
STANDALONE
}

# ==============================
# KUSTOMIZATION
# ==============================
generate_kustomization(){
  info "Generowanie kustomization.yaml..."
  cat > "${BASE_DIR}/kustomization.yaml" <<K
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${NAMESPACE}

resources:
  - service-account.yaml
  - configmap.yaml
  - secret.yaml
  - vault-config.yaml
  - vault-deployment.yaml
  - postgres.yaml
  - pgadmin.yaml
  - adminer.yaml # DODANO ADMINER
  - redis.yaml
  - kafka.yaml 
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - prometheus-config.yaml
  - prometheus-deployment.yaml
  - grafana-secret.yaml
  - grafana-deployment.yaml
  - loki-config.yaml
  - loki-deployment.yaml
  - promtail-config.yaml
  - promtail-deployment.yaml
  - tempo-config.yaml
  - tempo-deployment.yaml
  - kyverno-policy.yaml

# Poprawiono: 'commonLabels' na 'labels'
labels:
- pairs:
    app: webstack-gitops
    environment: development # KLUCZOWE DLA KYVERNO
    managed-by: argocd

images:
  - name: ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat
    newName: ${REGISTRY} 
    newTag: latest
K
}

# ==============================
# README (Zaktualizowana)
# ==============================
generate_readme(){
  info "Generowanie README.md..."
  cat > "${ROOT_DIR}/README.md" <<MD
# ${PROJECT} - Unified GitOps Stack (Finalna Wersja)

🚀 **Kompleksowa aplikacja z pełnym stack'iem DevOps**

## 📋 KOMPONENTY (WSZYSTKIE)
- **FastAPI** (App)
- **PostgreSQL** (DB)
- **pgAdmin** (DB UI)
- **Adminer** (DB UI Alternatywa)
- **Vault** (Secrets, z poprawionym initContainerem)
- **Kafka KRaft** (Messaging, bez Zookeepera)
- **Redis** (Cache)
- **Prometheus/Grafana/Loki/Tempo/Promtail** (Observability)
- **ArgoCD/Kyverno** (GitOps/Security)

## 🚀 FINALNE KROKI WDROŻENIA (KRYTYCZNE)

### 1. Generowanie i push do Git

Musisz wygenerować manifesty z **poprawionym Vaultem i Adminerem** i wypchnąć je do repozytorium.

\`\`\`bash
# 1. Usuń stary folder, aby zresetować pliki
rm -rf manifests/ argocd-application.yaml

# 2. Uruchom skrypt
./unified-deployment.sh generate

# 3. Dodaj, commituj i push do repo (użyj nazwy webstack-gitops!)
git add .
git commit -m "Final Fix: Vault initContainer for read-only config fix and added Adminer component."
git push -u origin main
\`\`\`

### 2. Czyszczenie starych zasobów w Kubernetes

**TO JEST KRYTYCZNE DLA NAPRAWY VAULT.** Musisz usunąć stary StatefulSet, aby ArgoCD mogło zastosować nową definicję z InitContainerem.

\`\`\`bash
# USUŃ WSZYSTKIE StatefulSety, Deploymenty i Ingress, by wymusić restart z poprawną konfiguracją
kubectl delete deployment -l app -n davtrowebdbvault
kubectl delete statefulset -l app -n davtrowebdbvault
kubectl delete ingress webstack-gitops -n davtrowebdbvault

# USUŃ PVC (Ważne dla resetu Vault/Postgres/Kafka/Redis)
kubectl delete pvc -l app=vault -n davtrowebdbvault
kubectl delete pvc -l app=postgres -n davtrowebdbvault
kubectl delete pvc -l app=kafka -n davtrowebdbvault
kubectl delete pvc -l app=redis -n davtrowebdbvault

# Wymuś pełną synchronizację w ArgoCD
argocd app sync webstack-gitops --refresh --prune
\`\`\`

### 3. Weryfikacja Podów i DNS

Po synchronizacji upewnij się, że wszystkie Pody są w stanie **Running**.

\`\`\`bash
kubectl get pods -n davtrowebdbvault
\`\`\`

**Upewnij się, że plik /etc/hosts zawiera nowe wpisy:**

\`\`\`
# Zastąp XXX.XXX.XXX.XXX adresem IP Twojego Ingress Controller'a
XXX.XXX.XXX.XXX app.webstack-gitops.local
XXX.XXX.XXX.XXX pgadmin.webstack-gitops.local
XXX.XXX.XXX.XXX grafana.webstack-gitops.local
XXX.XXX.XXX.XXX adminer.webstack-gitops.local 
\`\`\`

## 🌐 Dostęp
- **Aplikacja**: http://app.${PROJECT}.local
- **pgAdmin**: http://pgadmin.${PROJECT}.local (admin@admin.com / admin)
- **Adminer**: http://adminer.${PROJECT}.local (Server: \`postgres\`, User: \`appuser\`, Pass: \`apppass\`, DB: \`appdb\`)
- **Grafana**: http://grafana.${PROJECT}.local (admin / admin)
MD
}

# ==============================
# GŁÓWNA FUNKCJA
# ==============================
generate_all(){
  info "🚀 Rozpoczynam generowanie unified stack..."
  
  generate_structure
  generate_fastapi_app
  generate_html_template
  generate_dockerfile
  generate_github_actions
  generate_k8s_base
  generate_postgres
  generate_pgadmin
  generate_adminer # NOWY KOMPONENT
  generate_vault   # NAPRAWIONY KOMPONENT
  generate_redis
  generate_kafka
  generate_prometheus
  generate_grafana
  generate_loki
  generate_promtail
  generate_tempo
  generate_kyverno
  generate_argocd_app
  generate_argocd_standalone
  generate_kustomization
  generate_readme
  
  echo ""
  info "✅ WSZYSTKO GOTOWE! (Nazwa projektu to: ${PROJECT})"
  echo ""
  echo "⚠️ PROSZĘ PRZEJDŹ DO SEKCJI '🚀 FINALNE KROKI WDROŻENIA (KRYTYCZNE)' W README.MD LUB POWYŻEJ"
  echo "   MUSISZ ZASTOSOWAĆ KROK CZYSZCZENIA ZASOBÓW KUBERNETES, ABY NAPRAWIĆ VAULT!"
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
    echo "Unified Deployment Script"
    echo "Usage: $0 generate"
    exit 0
    ;;
  *)
    echo "❌ Nieprawidłowa komenda"
    echo "Użyj: $0 generate"
    exit 1
    ;;
esac
