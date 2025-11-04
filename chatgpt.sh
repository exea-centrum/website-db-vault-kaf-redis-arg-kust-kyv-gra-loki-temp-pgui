#!/usr/bin/env bash
set -euo pipefail

# Unified deployment script - combines website app with full GitOps stack
# Generates FastAPI app + Kubernetes manifests with ArgoCD, Vault, Postgres, Redis, Kafka, Grafana, Prometheus, Loki, Tempo, Kyverno

PROJECT="website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat"
NAMESPACE="davtrowebdbvault"
ORG="exea-centrum"
REGISTRY="ghcr.io/${ORG}/${PROJECT}"
REPO_URL="https://github.com/${ORG}/${PROJECT}.git"

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
# FASTAPI APLIKACJA (Z KAFKA I TRACINGIEM DLA TEMPO)
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
            api_version=(0, 10, 1) # Zgodność z nowszymi wersjami
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
    # ... (pytania ankiety bez zmian)
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
                # Kontynuujemy pomimo błędu Kafka, bo zapis do DB się powiódł
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
kafka-python==2.0.2  # <--- NOWA ZALEŻNOŚĆ
opentelemetry-api==1.22.0 # <--- NOWA ZALEŻNOŚĆ
opentelemetry-sdk==1.22.0 # <--- NOWA ZALEŻNOŚĆ
opentelemetry-instrumentation-fastapi==0.43b0 # <--- NOWA ZALEŻNOŚĆ
opentelemetry-exporter-otlp==1.22.0 # <--- NOWA ZALEŻNOŚĆ
EOF
}

# ==============================
# HTML TEMPLATE (skrócony dla czytelności)
# ==============================
generate_html_template(){
  info "Generowanie szablonu HTML..."
  # Kopiuj pełny HTML z deep.sh - tutaj używam skróconej wersji
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
# KUBERNETES MANIFESTS
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

  # App Deployment (Zaktualizowano: Dodano konfigurację Kafka i OpenTelemetry)
  cat > "${BASE_DIR}/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PROJECT}
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${PROJECT}
  template:
    metadata:
      labels:
        app: ${PROJECT}
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
        # KONFIGURACJA KAFKA
        - name: KAFKA_BOOTSTRAP_SERVERS
          value: kafka:9092
        # KONFIGURACJA TRACINGU DLA TEMPO (OTLP)
        - name: OTEL_SERVICE_NAME
          value: ${PROJECT}-fastapi
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: http://tempo:4317 # Tempo OTLP gRPC endpoint
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
spec:
  selector:
    app: ${PROJECT}
  ports:
    - port: 80
      targetPort: 8000
      protocol: TCP
  type: ClusterIP
EOF

  # Ingress
  cat > "${BASE_DIR}/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${PROJECT}
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: ${PROJECT}.local
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
EOF
}

# ==============================
# POSTGRES
# ==============================
generate_postgres(){
  info "Generowanie PostgreSQL..."
  cat > "${BASE_DIR}/postgres.yaml" <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: davtrowebdbvault
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
  namespace: davtrowebdbvault
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
# PGADMIN
# ==============================
generate_pgadmin(){
  info "Generowanie pgAdmin..."
  cat > "${BASE_DIR}/pgadmin.yaml" <<EOF
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
spec:
  selector:
    app: pgadmin
  ports:
  - port: 80
    targetPort: 80
EOF
}

# ==============================
# VAULT
# ==============================
generate_vault(){
  info "Generowanie Vault..."
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

  cat > "${BASE_DIR}/vault-deployment.yaml" <<VD
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
      containers:
      - name: vault
        image: hashicorp/vault:1.15.3
        args: ["server","-config=/vault/config/vault.hcl"]
        ports:
        - containerPort: 8200
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
VD
}

# ==============================
# REDIS
# ==============================
generate_redis(){
  info "Generowanie Redis..."
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

# ==============================
# KAFKA
# ==============================
generate_kafka(){
  info "Generowanie Kafka + Zookeeper..."
  cat > "${BASE_DIR}/kafka.yaml" <<'KAF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: zookeeper
  namespace: davtrowebdbvault
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
        env:
        - name: ALLOW_ANONYMOUS_LOGIN
          value: "yes"
---
apiVersion: v1
kind: Service
metadata:
  name: zookeeper
  namespace: davtrowebdbvault
spec:
  ports:
  - port: 2181
  selector:
    app: zookeeper
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: davtrowebdbvault
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
  namespace: davtrowebdbvault
spec:
  ports:
  - port: 9092
  selector:
    app: kafka
KAF
}

# ==============================
# PROMETHEUS
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
spec:
  ports:
  - port: 9090
  selector:
    app: prometheus
PD
}

# ==============================
# GRAFANA
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
spec:
  ports:
  - port: 3000
  selector:
    app: grafana
GD
}

# ==============================
# LOKI
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
spec:
  ports:
  - port: 3100
  selector:
    app: loki
LKD
}

# ==============================
# PROMTAIL
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
spec:
  replicas: 1
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
# TEMPO (Zaktualizowano: Dodano porty OTLP)
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
            grpc: # <--- WAŻNE: Odbiera ślady z aplikacji
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
spec:
  ports:
  - name: tempo-http
    port: 3200
    targetPort: 3200
  - name: otlp-grpc
    port: 4317 # Port dla OpenTelemetry (gRPC)
    targetPort: 4317
  - name: otlp-http
    port: 4318 # Port dla OpenTelemetry (HTTP)
    targetPort: 4318
  selector:
    app: tempo
TD
}

# ==============================
# KYVERNO POLICY
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
# ARGOCD APPLICATION
# ==============================
generate_argocd_app(){
  info "Generowanie ArgoCD Application..."
  cat > "${BASE_DIR}/argocd-app.yaml" <<'AA'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: website-db-stack
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.git
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
  name: website-db-stack
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.git
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
  cat > "${BASE_DIR}/kustomization.yaml" <<'K'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: davtrowebdbvault

resources:
  - service-account.yaml
  - configmap.yaml
  - secret.yaml
  - vault-config.yaml
  - vault-deployment.yaml
  - postgres.yaml
  - pgadmin.yaml
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

# Poprawiono: 'commonLabels' jest przestarzałe, używamy 'labels'
labels:
- pairs:
    app: website-db-stack
    environment: development
    managed-by: argocd

images:
  - name: ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat
    newTag: latest
K
}

# ==============================
# README (Zaktualizowana)
# ==============================
generate_readme(){
  info "Generowanie README.md..."
  cat > "${ROOT_DIR}/README.md" <<MD
# ${PROJECT} - Unified GitOps Stack (Zintegrowane Kafka i Tracing)

🚀 **Kompleksowa aplikacja z pełnym stack'iem DevOps**

## 📋 Komponenty

### Aplikacja
- **FastAPI** - Strona osobista z ankietą. **Wysyła wiadomości do Kafka i Tracing do Tempo.**
- **PostgreSQL** - Baza danych
- **pgAdmin** - Zarządzanie bazą danych

### GitOps & Orchestracja
- **ArgoCD** - Continuous Deployment
- **Kustomize** - Zarządzanie konfiguracją
- **Kyverno** - Policy enforcement

### Bezpieczeństwo
- **Vault** - Zarządzanie sekretami

### Messaging & Cache
- **Kafka + Zookeeper** - Kolejka wiadomości. **Aplikacja FastAPI jest Producentem.**
- **Redis** - Cache i kolejki

### Monitoring & Observability (Pełny Trójkąt)
- **Prometheus** - Metryki
- **Grafana** - Wizualizacja (Metryki, Logi, Ślady)
- **Loki** - Logi (Współpracuje z Promtail)
- **Tempo** - Distributed tracing. **Zbiera ślady OpenTelemetry z FastAPI.**
- **Promtail** - Agregacja logów

## 🚀 Użycie

### 1. Generowanie manifestów
\`\`\`bash
chmod +x unified-deployment.sh
./unified-deployment.sh generate
\`\`\`

### 2. Inicjalizacja i push do GitHub (KRYTYCZNE dla ArgoCD)
\`\`\`bash
# Upewnij się, że wszystkie pliki, w tym kafka.yaml, są dodane.
git init
git add .
git commit -m "Initial commit - unified stack with Kafka and Tempo tracing (Fixed Kustomization labels)"
git branch -M main
git remote add origin ${REPO_URL}
git push -u origin main
\`\`\`

### 3. Weryfikacja lokalnie (opcjonalnie)
\`\`\`bash
# Sprawdź czy Kustomize działa
kubectl kustomize manifests/base

# Sprawdź strukturę
tree manifests/
\`\`\`

### 4. Deploy z ArgoCD
\`\`\`bash
# Upewnij się że ArgoCD jest zainstalowany
kubectl get namespace argocd

# Zastosuj Application manifest
kubectl apply -f argocd-application.yaml

# Sprawdź status
kubectl get applications -n argocd
kubectl describe application website-db-stack -n argocd

# Zobacz logi sync
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
\`\`\`

### 5. Debug jeśli są problemy
\`\`\`bash
# Sprawdź czy repo jest dostępne dla ArgoCD
argocd repo list

# Dodaj repo jeśli nie ma
argocd repo add ${REPO_URL}

# Sprawdź czy manifesty są poprawne
kubectl kustomize manifests/base | kubectl apply --dry-run=client -f -
\`\`\`

## ⚠️ Typowe problemy

### "app path does not exist" lub "no such file or directory"
**Przyczyna**: Manifesty nie zostały jeszcze wypushowane do repo lub ścieżka jest błędna. **Upewnij się, że wykonałeś KROK 2.**

**Rozwiązanie**:
1. Upewnij się że zrobiłeś \`git push\` po generowaniu
2. Sprawdź czy folder \`manifests/base/\` istnieje w repo na GitHub
3. Sprawdź czy plik \`manifests/base/kustomization.yaml\` jest dostępny

### "Unable to generate manifests"
**Przyczyna**: Błąd w kustomization.yaml lub brakujący plik.

**Rozwiązanie**:
\`\`\`bash
# Test lokalny
kubectl kustomize manifests/base

# Sprawdź czy wszystkie pliki istnieją
ls -la manifests/base/
\`\`\`

### ArgoCD nie widzi repo
**Rozwiązanie**:
\`\`\`bash
# Dodaj credentials dla prywatnego repo
kubectl create secret generic repo-creds \\
  --from-literal=url=${REPO_URL} \\
  --from-literal=password=YOUR_GITHUB_TOKEN \\
  --from-literal=username=YOUR_GITHUB_USERNAME \\
  -n argocd
\`\`\`

## 🌐 Dostęp

- **Aplikacja**: http://${PROJECT}.local
- **pgAdmin**: http://pgadmin.${PROJECT}.local (admin@admin.com / admin)
- **Grafana**: http://grafana.${PROJECT}.local (admin / admin)
- **Vault**: http://vault.${PROJECT}.local:8200

## 📊 Baza danych

### Tabele:
- \`survey_responses\` - Odpowiedzi z ankiety
- \`page_visits\` - Statystyki odwiedzin
- \`contact_messages\` - Wiadomości kontaktowe

## 🔐 Sekretna konfiguracja

### GitHub Secrets wymagane:
- \`GHCR_PAT\` - Personal Access Token dla GitHub Container Registry

## 📦 Namespace
\`${NAMESPACE}\`

## 🏗️ Architektura (Zintegrowana)

\`\`\`
┌─────────────────────────────────────────────────────┐
│                    ArgoCD                           │
│              (Continuous Deployment)                │
└──────────────────┬──────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────┐
│              Kubernetes Cluster                     │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐               │
│  │   FastAPI    │  │  PostgreSQL  │               │
│  │   Website    │──│   Database   │               │
│  └──────────────┘  └──────────────┘               │
│         │ Tracing (Tempo)                           │
│         ├────────────┬─────────────┬───────────────┤
│         ▼            ▼             ▼               ▼
│  ┌──────────┐  ┌─────────┐  ┌─────────┐    ┌──────────┐
│  │  Redis   │  │  Kafka  │  │  Vault  │    │ pgAdmin  │
│  └──────────┘  └─────────┘  └─────────┘    └──────────┘
│                  ^                                  │
│                  │ Wiadomości (Survey Topic)          │
│                  │                                  │
│  ┌─────────────────────────────────────────────┐  │
│  │         Observability Stack                 │  │
│  │  ┌──────────┐ ┌─────────┐ ┌──────────┐    │  │
│  │  │Prometheus│ │ Grafana │ │   Loki   │    │  │
│  │  └──────────┘ └─────────┘ └──────────┘    │  │
│  │  ┌──────────┐ ┌─────────┐                 │  │
│  │  │  Tempo   │ │Promtail │                 │  │
│  │  └──────────┘ └─────────┘                 │  │
│  └─────────────────────────────────────────────┘  │
│                                                     │
│  ┌─────────────────────────────────────────────┐  │
│  │              Kyverno Policies               │  │
│  │         (Policy Enforcement)                │  |
│  └─────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
\`\`\`

## 🛠️ Rozwój

### Struktura projektu:
\`\`\`
.
├── app/
│   ├── main.py              # FastAPI (Producent Kafka, OpenTelemetry Tracing)
│   ├── requirements.txt     # Zależności Python (+kafka-python, +opentelemetry)
│   └── templates/
│       └── index.html       # Frontend
├── manifests/
│   └── base/               # Manifesty Kubernetes (Deployment ma Env Vars dla Kafka/Tempo)
│       ├── *.yaml
│       └── kustomization.yaml # POPRAWIONY: Używa 'labels' zamiast 'commonLabels'
├── .github/
│   └── workflows/
│       └── ci.yml          # GitHub Actions
├── Dockerfile
└── unified-deployment.sh   # Ten skrypt
\`\`\`

## 📝 Licencja

MIT License - Dawid Trojanowski © 2025
MD
}

# ==============================
# GŁÓWNA FUNKCJA
# ==============================
generate_all(){
  info "🚀 Rozpoczynam generowanie unified stack..."
  echo ""
  
  generate_structure
  generate_fastapi_app
  generate_html_template
  generate_dockerfile
  generate_github_actions
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
  generate_kyverno
  generate_argocd_app
  generate_argocd_standalone
  generate_kustomization
  generate_readme
  
  echo ""
  info "✅ WSZYSTKO GOTOWE! (Zintegrowano Kafka i Tracing dla Tempo)"
  echo ""
  echo "📦 Wygenerowano:"
  echo "   ✓ FastAPI aplikacja w app/ (Producent Kafka, Tracing OTLP)"
  echo "   ✓ Dockerfile"
  echo "   ✓ GitHub Actions workflow"
  echo "   ✓ Kubernetes manifesty w manifests/base/"
  echo "   ✓ argocd-application.yaml (standalone w root)"
  echo "   ✓ README.md"
  echo ""
  echo "🎯 Komponenty (Zintegrowane):"
  echo "   ✓ FastAPI + PostgreSQL + pgAdmin"
  echo "   ✓ Vault (secrets management)"
  echo "   ✓ Redis (cache)"
  echo "   ✓ Kafka + Zookeeper (messaging, cel: survey-topic)"
  echo "   ✓ Prometheus + Grafana (monitoring)"
  echo "   ✓ Loki + Promtail (logging)"
  echo "   ✓ Tempo (tracing, odbiera ślady z FastAPI na porcie 4317)"
  echo "   ✓ ArgoCD (GitOps)"
  echo "   ✓ Kyverno (policies)"
  echo ""
  echo "🚀 Następne kroki (Powtórz te kroki, aby naprawić błąd ArgoCD!):"
  echo ""
  echo "1️⃣ Inicjalizacja Git i push:"
  echo "   git init"
  echo "   git add ."
  echo "   git commit -m 'Initial commit - unified stack with Kafka and Tempo tracing (Fixed Kustomization labels)'"
  echo "   git branch -M main"
  echo "   git remote add origin ${REPO_URL}"
  echo "   git push -u origin main"
  echo ""
  echo "2️⃣ Weryfikacja struktury:"
  echo "   tree manifests/"
  echo ""
  echo "3️⃣ Test lokalny Kustomize:"
  echo "   kubectl kustomize manifests/base"
  echo ""
  echo "4️⃣ Deploy ArgoCD Application (po push do repo):"
  echo "   kubectl apply -f argocd-application.yaml"
  echo ""
  echo "5️⃣ Sprawdź status w ArgoCD:"
  echo "   kubectl get applications -n argocd"
  echo "   kubectl describe application website-db-stack -n argocd"
  echo ""
  echo "⚠️  WAŻNE: Upewnij się że:"
  echo "   ✓ Repozytorium ${REPO_URL} istnieje"
  echo "   ✓ ArgoCD jest zainstalowany (kubectl get ns argocd)"
  echo "   ✓ Folder manifests/base/ zawiera wszystkie pliki"
  echo ""
  echo "🌐 Dostęp:"
  echo "   App: http://${PROJECT}.local"
  echo "   pgAdmin: http://pgadmin.${PROJECT}.local"
  echo "   Grafana: http://grafana.${PROJECT}.local"
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
    echo ""
    echo "Usage: $0 generate"
    echo ""
    echo "Generuje kompletny stack z aplikacją FastAPI i infrastrukturą Kubernetes"
    ;;
  *)
    echo "❌ Nieprawidłowa komenda"
    echo "Użyj: $0 generate"
    echo "Lub: $0 help"
    exit 1
    ;;
esac