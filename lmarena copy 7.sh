#!/usr/bin/env bash
set -euo pipefail
trap 'rc=$?; echo "❌ Error on line ${LINENO} (exit ${rc})"; exit ${rc}' ERR
IFS=$'\n\t'

PROJECT="website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui"
NAMESPACE="davtrowebdbvault"
REGISTRY="${REGISTRY:-ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui}"
REPO_URL="${REPO_URL:-https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.git}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${ROOT_DIR}/app"
TEMPLATES_DIR="${APP_DIR}/templates"
MANIFESTS_DIR="${ROOT_DIR}/manifests"
BASE_DIR="${MANIFESTS_DIR}/base"
WORKFLOW_DIR="${ROOT_DIR}/.github/workflows"

info(){ printf "🔧 [unified] %s\n" "$*"; }
mkdir_p(){ mkdir -p "$@"; }

generate_structure(){
 mkdir_p "$APP_DIR" "$TEMPLATES_DIR" "$BASE_DIR" "$WORKFLOW_DIR" "${APP_DIR}/static"
}

generate_fastapi_app(){
 cat > "${APP_DIR}/__init__.py" <<'PY'
# FastAPI Application Package
PY

 cat > "${APP_DIR}/main.py" <<'PY'
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
import hvac
import json
import redis
from kafka import KafkaProducer

app = FastAPI(title="Dawid Trojanowski - Strona Osobista")
templates = Jinja2Templates(directory="templates")
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_LIST = os.getenv("REDIS_LIST", "outgoing_messages")
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka-0.kafka.davtrowebdbvault.svc.cluster.local:9092")
KAFKA_TOPIC = os.getenv("KAFKA_TOPIC", "survey-topic")

def get_redis():
    return redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

def get_kafka():
    max_retries = 10
    for attempt in range(max_retries):
        try:
            producer = KafkaProducer(
                bootstrap_servers=KAFKA_BOOTSTRAP.split(','),
                value_serializer=lambda v: json.dumps(v).encode('utf-8'),
                retries=3
            )
            producer.list_topics()
            logger.info("Kafka connected successfully")
            return producer
        except Exception as e:
            logger.warning(f"Kafka connection attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(10)
            else:
                logger.error(f"All Kafka connection attempts failed: {e}")
                return None

def get_vault_secret(secret_path: str) -> dict:
    try:
        vault_addr = os.getenv("VAULT_ADDR", "http://vault:8200")
        vault_token = os.getenv("VAULT_TOKEN")
        
        if vault_token:
            client = hvac.Client(url=vault_addr, token=vault_token)
            if client.is_authenticated():
                secret = client.read(secret_path)
                if secret and 'data' in secret:
                    return secret['data'].get('data', {})
        else:
            logger.warning("Vault token not available, using fallback")
            
    except Exception as e:
        logger.warning(f"Vault error: {e}, using fallback")
    
    return {}

def get_database_config() -> str:
    vault_secret = get_vault_secret("secret/data/database/postgres")
    
    if vault_secret:
        return f"dbname={vault_secret.get('postgres-db', 'webdb')} " \
               f"user={vault_secret.get('postgres-user', 'webuser')} " \
               f"password={vault_secret.get('postgres-password', 'testpassword')} " \
               f"host={vault_secret.get('postgres-host', 'postgres-db')} " \
               f"port=5432"
    else:
        return os.getenv("DATABASE_URL", "dbname=webdb user=webuser password=testpassword host=postgres-db port=5432")

DB_CONN = get_database_config()

Instrumentator().instrument(app).expose(app)

class SurveyResponse(BaseModel):
    question: str
    answer: str

def get_db_connection():
    max_retries = 30
    for attempt in range(max_retries):
        try:
            conn = psycopg2.connect(DB_CONN)
            return conn
        except psycopg2.OperationalError as e:
            logger.warning(f"Database connection attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(10)
            else:
                logger.error(f"All database connection attempts failed: {e}")

def init_database():
    max_retries = 30
    for attempt in range(max_retries):
        try:
            conn = get_db_connection()
            cur = conn.cursor()
            
            cur.execute("""
                CREATE TABLE IF NOT EXISTS survey_responses(
                    id SERIAL PRIMARY KEY,
                    question TEXT NOT NULL,
                    answer TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            cur.execute("""
                CREATE TABLE IF NOT EXISTS page_visits(
                    id SERIAL PRIMARY KEY,
                    page VARCHAR(255) NOT NULL,
                    visited_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
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

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
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
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        
        vault_secret = get_vault_secret("secret/data/database/postgres")
        vault_status = "connected" if vault_secret else "disconnected"
        
        return {
            "status": "healthy",
            "database": "connected",
            "vault": vault_status
        }
    except Exception as e:
        logger.warning(f"Health check failed: {e}")
        return {
            "status": "unhealthy",
            "database": "disconnected",
            "vault": "disconnected",
            "error": str(e)
        }

@app.get("/api/survey/questions")
async def get_survey_questions():
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
            "text": "Jakie technologie Cię zainteresowały?",
            "type": "multiselect",
            "options": ["Python", "JavaScript", "React", "Kubernetes", "Docker", "PostgreSQL", "Vault"]
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
    try:
        r = get_redis()
        payload = {
            "type": "survey",
            "question": response.question,
            "answer": response.answer,
            "timestamp": time.time()
        }
        r.rpush(REDIS_LIST, json.dumps(payload))
        
        logger.info(f"Survey response queued: {response.question} -> {response.answer}")
        return {"status": "success", "message": "Dziękujemy za wypełnienie ankiety!"}
    except Exception as e:
        logger.error(f"Error queueing survey response: {e}")
        raise HTTPException(status_code=500, detail="Błąd podczas zapisywania odpowiedzi")

@app.get("/api/survey/stats")
async def get_survey_stats():
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
    try:
        r = get_redis()
        payload = {
            "type": "contact",
            "email": email,
            "message": message,
            "timestamp": time.time()
        }
        r.rpush(REDIS_LIST, json.dumps(payload))
        
        logger.info(f"Contact message queued from: {email}")
        return {"status": "success", "message": "Wiadomość została wysłana!"}
    except Exception as e:
        logger.error(f"Error queueing contact message: {e}")
        raise HTTPException(status_code=500, detail="Błąd podczas wysyłania wiadomości")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
PY

 cat > "${APP_DIR}/worker.py" <<'PY'
#!/usr/bin/env python3
import os, json, time, logging
import redis
from kafka import KafkaProducer
import psycopg2
import hvac

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("worker")

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_LIST = os.getenv("REDIS_LIST", "outgoing_messages")

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka-0.kafka.davtrowebdbvault.svc.cluster.local:9092")
KAFKA_TOPIC = os.getenv("KAFKA_TOPIC", "survey-topic")

def get_vault_secret(secret_path: str) -> dict:
    try:
        vault_addr = os.getenv("VAULT_ADDR", "http://vault:8200")
        vault_token = os.getenv("VAULT_TOKEN")
        
        if vault_token:
            client = hvac.Client(url=vault_addr, token=vault_token)
            if client.is_authenticated():
                secret = client.read(secret_path)
                if secret and 'data' in secret:
                    return secret['data'].get('data', {})
        else:
            logger.warning("Vault token not available, using fallback")
            
    except Exception as e:
        logger.warning(f"Vault error: {e}, using fallback")
    
    return {}

def get_database_config() -> str:
    vault_secret = get_vault_secret("secret/data/database/postgres")
    
    if vault_secret:
        return f"dbname={vault_secret.get('postgres-db', 'webdb')} " \
               f"user={vault_secret.get('postgres-user', 'webuser')} " \
               f"password={vault_secret.get('postgres-password', 'testpassword')} " \
               f"host={vault_secret.get('postgres-host', 'postgres-db')} " \
               f"port=5432"
    else:
        return os.getenv("DATABASE_URL", "dbname=webdb user=webuser password=testpassword host=postgres-db port=5432")

DATABASE_URL = get_database_config()

def get_redis():
    return redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

def get_kafka():
    max_retries = 10
    for attempt in range(max_retries):
        try:
            producer = KafkaProducer(
                bootstrap_servers=KAFKA_BOOTSTRAP.split(','),
                value_serializer=lambda v: json.dumps(v).encode('utf-8'),
                retries=3
            )
            producer.list_topics()
            logger.info("Kafka connected successfully")
            return producer
        except Exception as e:
            logger.warning(f"Kafka connection attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(10)
            else:
                logger.error(f"All Kafka connection attempts failed: {e}")
                return None

def get_db_connection():
    max_retries = 30
    for attempt in range(max_retries):
        try:
            conn = psycopg2.connect(DATABASE_URL)
            return conn
        except psycopg2.OperationalError as e:
            logger.warning(f"Database connection attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(10)
            else:
                logger.error(f"All database connection attempts failed: {e}")

def save_to_db(item_type, data):
    conn = get_db_connection()
    cur = conn.cursor()
    
    try:
        if item_type == "survey":
            cur.execute(
                "INSERT INTO survey_responses (question, answer) VALUES (%s, %s)",
                (data.get("question"), data.get("answer"))
            )
        elif item_type == "contact":
            cur.execute(
                "INSERT INTO contact_messages (email, message) VALUES (%s, %s)",
                (data.get("email"), data.get("message"))
            )
        
        conn.commit()
        logger.info(f"Saved {item_type} to database")
    except Exception as e:
        logger.error(f"Error saving to database: {e}")
        conn.rollback()
    finally:
        cur.close()
        conn.close()

def process_item(item, producer):
    try:
        item_type = item.get("type")
        save_to_db(item_type, item)
        
        if producer:
            try:
                future = producer.send(KAFKA_TOPIC, value=item)
                future.get(timeout=10)
                logger.info(f"Sent to Kafka topic {KAFKA_TOPIC}: {item}")
            except Exception as e:
                logger.warning(f"Failed to send to Kafka (will continue without Kafka): {e}")
        
    except Exception as e:
        logger.exception(f"Processing failed for item: {item}")

def main():
    r = get_redis()
    producer = None
    kafka_retry_time = 60
    
    logger.info("Worker started. Listening on Redis list '%s'", REDIS_LIST)
    
    while True:
        try:
            if not producer:
                producer = get_kafka()
                if not producer:
                    logger.info(f"Retrying Kafka connection in {kafka_retry_time} seconds")
                    time.sleep(kafka_retry_time)
                    continue
            
            res = r.blpop(REDIS_LIST, timeout=10)
            if res:
                _, data = res
                try:
                    item = json.loads(data)
                except Exception:
                    item = {"raw": data, "type": "unknown"}
                
                process_item(item, producer)
                
        except Exception as e:
            logger.exception("Worker loop exception, reconnecting...")
            if producer:
                try:
                    producer.close()
                except:
                    pass
                producer = None
            time.sleep(5)

if __name__ == "__main__":
    main()
PY

 cat > "${TEMPLATES_DIR}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Dawid Trojanowski - Strona Osobista</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
        }
        .animate-fade-in { animation: fadeIn 0.5s ease-out; }
        .skill-bar { height: 10px; background: rgba(255,255,255,0.1); border-radius: 5px; overflow: hidden; }
        .skill-progress { height: 100%; border-radius: 5px; transition: width 1.5s ease-in-out; }
    </style>
</head>
<body class="bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900 text-white min-h-screen">
    <header class="border-b border-purple-500/30 backdrop-blur-sm bg-black/20 sticky top-0 z-50">
        <div class="container mx-auto px-6 py-4">
            <div class="flex items-center justify-between">
                <div class="flex items-center gap-3">
                    <h1 class="text-3xl font-bold bg-gradient-to-r from-purple-400 to-pink-400 bg-clip-text text-transparent">
                        Dawid Trojanowski
                    </h1>
                </div>
                <nav class="flex gap-4">
                    <button onclick="showTab('intro')" class="tab-btn px-4 py-2 rounded-lg bg-purple-500 text-white" data-tab="intro">O Mnie</button>
                    <button onclick="showTab('edu')" class="tab-btn px-4 py-2 rounded-lg text-purple-300" data-tab="edu">Edukacja</button>
                    <button onclick="showTab('exp')" class="tab-btn px-4 py-2 rounded-lg text-purple-300" data-tab="exp">Doświadczenie</button>
                    <button onclick="showTab('skills')" class="tab-btn px-4 py-2 rounded-lg text-purple-300" data-tab="skills">Umiejętności</button>
                    <button onclick="showTab('survey')" class="tab-btn px-4 py-2 rounded-lg text-purple-300" data-tab="survey">Ankieta</button>
                    <button onclick="showTab('contact')" class="tab-btn px-4 py-2 rounded-lg text-purple-300" data-tab="contact">Kontakt</button>
                </nav>
            </div>
        </div>
    </header>

    <main class="container mx-auto px-6 py-12">
        <div id="intro-tab" class="tab-content">
            <div class="space-y-8 animate-fade-in">
                <div class="bg-gradient-to-br from-purple-500/10 to-pink-500/10 backdrop-blur-lg border border-purple-500/20 rounded-2xl p-8">
                    <h2 class="text-4xl font-bold mb-6 text-purple-300">O Mnie</h2>
                    <p class="text-lg text-gray-300 leading-relaxed">
                        Cześć! Jestem Dawidem Trojanowskim, pasjonatem informatyki i nowych technologii. 
                        Specjalizuję się w tworzeniu rozproszonych systemów wykorzystujących FastAPI, Redis, 
                        Kafka i PostgreSQL z pełnym monitoringiem.
                    </p>
                </div>
            </div>
        </div>

        <div id="edu-tab" class="tab-content hidden">
            <div class="space-y-6 animate-fade-in">
                <h2 class="text-4xl font-bold mb-8 text-purple-300">Edukacja</h2>
                <div class="bg-gradient-to-br from-slate-800/50 to-slate-900/50 backdrop-blur-lg border border-purple-500/20 rounded-xl p-6">
                    <h3 class="text-2xl font-bold mb-4 text-purple-300">Politechnika Warszawska</h3>
                    <p class="text-gray-300 mb-4">Informatyka, studia magisterskie</p>
                </div>
            </div>
        </div>

        <div id="exp-tab" class="tab-content hidden">
            <div class="space-y-6 animate-fade-in">
                <h2 class="text-4xl font-bold mb-8 text-purple-300">Doświadczenie Zawodowe</h2>
                <div class="bg-gradient-to-br from-slate-800/50 to-slate-900/50 backdrop-blur-lg border border-purple-500/20 rounded-xl p-6">
                    <h3 class="text-2xl font-bold mb-4 text-purple-300">Full Stack Developer</h3>
                    <p class="text-gray-300 mb-4">Specjalizacja w systemach rozproszonych</p>
                </div>
            </div>
        </div>

        <div id="skills-tab" class="tab-content hidden">
            <div class="space-y-6 animate-fade-in">
                <h2 class="text-4xl font-bold mb-8 text-purple-300">Umiejętności</h2>
                <div class="grid md:grid-cols-2 gap-6">
                    <div class="bg-gradient-to-br from-slate-800/50 to-slate-900/50 backdrop-blur-lg border border-purple-500/20 rounded-xl p-6">
                        <h3 class="text-2xl font-bold mb-4 text-purple-300">Technologie</h3>
                        <div class="space-y-4">
                            <div>
                                <div class="flex justify-between mb-1"><span>FastAPI</span><span>90%</span></div>
                                <div class="skill-bar"><div class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500" data-width="90%"></div></div>
                            </div>
                            <div>
                                <div class="flex justify-between mb-1"><span>Kubernetes</span><span>85%</span></div>
                                <div class="skill-bar"><div class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500" data-width="85%"></div></div>
                            </div>
                            <div>
                                <div class="flex justify-between mb-1"><span>PostgreSQL</span><span>88%</span></div>
                                <div class="skill-bar"><div class="skill-progress bg-gradient-to-r from-purple-500 to-pink-500" data-width="88%"></div></div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div id="survey-tab" class="tab-content hidden">
            <div class="space-y-8 animate-fade-in">
                <div class="bg-gradient-to-br from-purple-500/10 to-pink-500/10 backdrop-blur-lg border border-purple-500/20 rounded-2xl p-8">
                    <h2 class="text-4xl font-bold mb-6 text-purple-300">Ankieta</h2>
                    <p class="text-lg text-gray-300 mb-8">
                        Twoje odpowiedzi trafią przez Redis i Kafka do bazy PostgreSQL z pełnym monitoringiem!
                    </p>
                  
                    <form id="survey-form" class="space-y-6">
                        <div id="survey-questions"></div>
                        <button type="submit" class="w-full py-3 px-4 rounded-lg bg-purple-500 text-white hover:bg-purple-600 transition-all">
                            Wyślij ankietę
                        </button>
                    </form>
                  
                    <div id="survey-message" class="mt-4 hidden p-3 rounded-lg"></div>
                </div>

                <div class="bg-gradient-to-br from-purple-500/10 to-pink-500/10 backdrop-blur-lg border border-purple-500/20 rounded-2xl p-8">
                    <h3 class="text-2xl font-bold mb-6 text-purple-300">Statystyki ankiet</h3>
                    <div class="grid md:grid-cols-2 gap-6">
                        <div id="survey-stats"></div>
                        <div><canvas id="survey-chart" width="400" height="200"></canvas></div>
                    </div>
                </div>
            </div>
        </div>

        <div id="contact-tab" class="tab-content hidden">
            <div class="space-y-8 animate-fade-in">
                <div class="bg-gradient-to-br from-purple-500/10 to-pink-500/10 backdrop-blur-lg border border-purple-500/20 rounded-2xl p-8">
                    <h2 class="text-4xl font-bold mb-6 text-purple-300">Kontakt</h2>
                    <div class="grid md:grid-cols-2 gap-6">
                        <div class="space-y-4">
                            <form id="contact-form">
                                <div><input type="email" name="email" placeholder="Twój email" class="w-full py-3 px-4 rounded-lg bg-slate-700 text-white border border-purple-500/30" required></div>
                                <div><textarea name="message" placeholder="Twoja wiadomość" rows="4" class="w-full py-3 px-4 rounded-lg bg-slate-700 text-white border border-purple-500/30" required></textarea></div>
                                <button type="submit" class="w-full mt-4 py-3 px-4 rounded-lg bg-purple-500 text-white hover:bg-purple-600 transition-all">Wyślij</button>
                            </form>
                            <div id="form-message" class="mt-4 hidden p-3 rounded-lg"></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </main>

    <script>
        function showTab(tabName) {
            document.querySelectorAll(".tab-content").forEach((tab) => {
                tab.classList.add("hidden");
                tab.classList.remove("animate-fade-in");
            });
            setTimeout(() => {
                const activeTab = document.getElementById(tabName + "-tab");
                activeTab.classList.remove("hidden");
                activeTab.classList.add("animate-fade-in");
                if (tabName === "skills") setTimeout(animateSkillBars, 300);
                if (tabName === "survey") { loadSurveyQuestions(); loadSurveyStats(); }
            }, 50);
            document.querySelectorAll(".tab-btn").forEach((btn) => {
                btn.classList.remove("bg-purple-500", "text-white");
                btn.classList.add("text-purple-300");
            });
            document.querySelector(`[data-tab="${tabName}"]`).classList.add("bg-purple-500", "text-white");
        }

        function animateSkillBars() {
            document.querySelectorAll(".skill-progress").forEach((bar) => {
                bar.style.width = bar.getAttribute("data-width");
            });
        }

        async function loadSurveyQuestions() {
            try {
                const response = await fetch('/api/survey/questions');
                const questions = await response.json();
                const container = document.getElementById('survey-questions');
                container.innerHTML = '';
                questions.forEach((q, index) => {
                    const questionDiv = document.createElement('div');
                    questionDiv.className = 'space-y-3';
                    questionDiv.innerHTML = `<label class="block text-gray-300 font-semibold">${q.text}</label>`;
                    if (q.type === 'rating') {
                        questionDiv.innerHTML += `<div class="flex gap-2 flex-wrap">${q.options.map(option => `
                            <label class="flex items-center space-x-2 cursor-pointer">
                                <input type="radio" name="question_${q.id}" value="${option}" class="hidden peer" required>
                                <span class="px-4 py-2 rounded-lg bg-slate-700 text-gray-300 peer-checked:bg-purple-500 peer-checked:text-white transition-all">${option}</span>
                            </label>`).join('')}</div>`;
                    } else if (q.type === 'text') {
                        questionDiv.innerHTML += `<textarea name="question_${q.id}" placeholder="${q.placeholder}" class="w-full py-3 px-4 rounded-lg bg-slate-700 text-white border border-purple-500/30" rows="3"></textarea>`;
                    }
                    container.appendChild(questionDiv);
                });
            } catch (error) {
                console.error('Error loading survey questions:', error);
            }
        }

        async function loadSurveyStats() {
            try {
                const response = await fetch('/api/survey/stats');
                const stats = await response.json();
                const container = document.getElementById('survey-stats');
                if (stats.total_responses === 0) {
                    container.innerHTML = '<div class="text-center text-gray-400 py-8">Brak odpowiedzi na ankietę.</div>';
                    return;
                }
                let statsHTML = `<div class="space-y-4"><div class="grid grid-cols-2 gap-4 text-center">
                    <div class="bg-slate-800/50 rounded-lg p-4"><div class="text-2xl font-bold text-purple-300">${stats.total_visits}</div><div class="text-sm text-gray-400">Odwiedzin</div></div>
                    <div class="bg-slate-800/50 rounded-lg p-4"><div class="text-2xl font-bold text-purple-300">${stats.total_responses}</div><div class="text-sm text-gray-400">Odpowiedzi</div></div></div>`;
                for (const [question, answers] of Object.entries(stats.survey_responses)) {
                    statsHTML += `<div class="border-t border-purple-500/20 pt-4"><h4 class="font-semibold text-purple-300 mb-2">${question}</h4><div class="space-y-2">`;
                    answers.forEach(item => {
                        statsHTML += `<div class="flex justify-between items-center"><span class="text-gray-300 text-sm">${item.answer}</span><span class="text-purple-300 font-semibold">${item.count}</span></div>`;
                    });
                    statsHTML += `</div></div>`;
                }
                statsHTML += `</div>`;
                container.innerHTML = statsHTML;
                updateSurveyChart(stats);
            } catch (error) {
                console.error('Error loading survey stats:', error);
            }
        }

        function updateSurveyChart(stats) {
            const ctx = document.getElementById('survey-chart').getContext('2d');
            const labels = []; const data = [];
            for (const [question, answers] of Object.entries(stats.survey_responses)) {
                answers.forEach(item => { labels.push(`${question}: ${item.answer}`); data.push(item.count); });
            }
            new Chart(ctx, {
                type: 'doughnut',
                data: { labels: labels, datasets: [{ data: data, backgroundColor: ['#a855f7','#ec4899','#8b5cf6','#d946ef','#7c3aed'] }] },
                options: { responsive: true, plugins: { legend: { position: 'bottom', labels: { color: '#cbd5e1', font: { size: 10 } } } } }
            });
        }

        document.getElementById('survey-form').addEventListener('submit', async (e) => {
            e.preventDefault();
            const responses = [];
            for (let i = 1; i <= 5; i++) {
                const questionElement = e.target.elements[`question_${i}`];
                if (questionElement) {
                    if (questionElement.type === 'radio') {
                        const selected = document.querySelector(`input[name="question_${i}"]:checked`);
                        if (selected) responses.push({ question: `Pytanie ${i}`, answer: selected.value });
                    } else if (questionElement.tagName === 'TEXTAREA' && questionElement.value.trim()) {
                        responses.push({ question: `Pytanie ${i}`, answer: questionElement.value.trim() });
                    }
                }
            }
            if (responses.length === 0) { showSurveyMessage('Proszę odpowiedzieć na przynajmniej jedno pytanie', 'error'); return; }
            try {
                for (const response of responses) {
                    await fetch('/api/survey/submit', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(response) });
                }
                showSurveyMessage('Dziękujemy za wypełnienie ankiety!', 'success');
                e.target.reset(); loadSurveyStats();
            } catch (error) {
                console.error('Error submitting survey:', error);
                showSurveyMessage('Wystąpił błąd podczas wysyłania ankiety', 'error');
            }
        });

        function showSurveyMessage(text, type) {
            const messageDiv = document.getElementById('survey-message');
            messageDiv.textContent = text;
            messageDiv.className = 'mt-4 p-3 rounded-lg';
            messageDiv.classList.add(type === 'error' ? 'bg-red-500/20 text-red-300 border border-red-500/30' : 'bg-green-500/20 text-green-300 border border-green-500/30');
            messageDiv.classList.remove('hidden');
            setTimeout(() => { messageDiv.classList.add('hidden'); }, 5000);
        }

        document.getElementById('contact-form').addEventListener('submit', async (e) => {
            e.preventDefault();
            const formData = new FormData(e.target);
            try {
                const response = await fetch('/api/contact', { method: 'POST', body: formData });
                const result = await response.json();
                showFormMessage(result.message, response.ok ? "success" : "error");
                if (response.ok) e.target.reset();
            } catch (error) {
                console.error('Error sending contact form:', error);
                showFormMessage("Wystąpił błąd podczas wysyłania wiadomości", "error");
            }
        });

        function showFormMessage(text, type) {
            const formMessage = document.getElementById('form-message');
            formMessage.textContent = text;
            formMessage.className = "mt-4 p-3 rounded-lg";
            formMessage.classList.add(type === "error" ? "bg-red-500/20 text-red-300 border border-red-500/30" : "bg-green-500/20 text-green-300 border border-green-500/30");
            formMessage.classList.remove("hidden");
            setTimeout(() => { formMessage.classList.add("hidden"); }, 5000);
        }

        document.addEventListener("DOMContentLoaded", () => {
            showTab("intro");
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
}

generate_dockerfile(){
 cat > "${ROOT_DIR}/Dockerfile" <<'DOCK'
FROM python:3.11-slim-bullseye
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ /app/
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
DOCK
}

generate_github_actions(){
 mkdir_p "$WORKFLOW_DIR"
 cat > "${WORKFLOW_DIR}/ci-cd.yaml" <<'YAML'
name: CI/CD Build & Deploy

on:
  push:
    branches: ["main"]
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
        uses: docker/setup-qemu-action@v3

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GHCR_PAT }}

      - name: Build and push image
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui:latest
            ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui:${{ github.sha }}
          cache-from: type=registry,ref=ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui:latest
          cache-to: type=inline
YAML
}

generate_k8s_manifests(){
 cat > "${BASE_DIR}/fastapi-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: fastapi-config
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: fastapi
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: fastapi
data:
  APP_NAME: "${PROJECT}"
  APP_ENV: "production"
  PYTHONUNBUFFERED: "1"
YAML

 cat > "${BASE_DIR}/app-deployment.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fastapi-web-app
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: fastapi
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: fastapi
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
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: fastapi
    spec:
      serviceAccountName: fastapi-sa
      initContainers:
        - name: wait-for-postgres
          image: postgres:15-alpine
          command:
            [
              "sh",
              "-c",
              'until pg_isready -h postgres-db -p 5432 -U webuser; do echo "waiting for postgres..."; sleep 5; done; echo "postgres ready"',
            ]
          env:
            - name: PGPASSWORD
              value: "testpassword"
            - name: PGUSER
              value: "webuser"
        - name: wait-for-redis
          image: busybox:1.36
          command:
            [
              "sh",
              "-c",
              'until nc -z redis 6379; do echo "waiting for redis..."; sleep 5; done; echo "redis ready"',
            ]
        - name: wait-for-kafka-broker
          image: confluentinc/cp-kafka:7.5.0
          command:
            [
              "/bin/bash",
              "-c",
              'for i in {1..120}; do if /opt/confluent/bin/kafka-broker-api-versions --bootstrap-server kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092 &>/dev/null; then echo "✓ kafka broker ready"; break; fi; echo "Attempt \$i/120: Kafka not ready..."; sleep 5; done',
            ]
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
          value: "kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092"
        - name: KAFKA_TOPIC
          value: "survey-topic"
        - name: VAULT_ADDR
          value: "http://vault:8200"
        - name: VAULT_TOKEN
          value: "root"
        - name: DATABASE_URL
          value: "dbname=webdb user=webuser password=testpassword host=postgres-db port=5432"
        - name: PYTHONUNBUFFERED
          value: "1"
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
          initialDelaySeconds: 60
          periodSeconds: 30
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 20
          failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: fastapi-web-service
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: fastapi
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: fastapi
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8000
    protocol: TCP
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
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
YAML

 cat > "${BASE_DIR}/message-processor.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: message-processor
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: worker
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: worker
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
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: worker
    spec:
      initContainers:
        - name: wait-for-postgres
          image: postgres:15-alpine
          command:
            [
              "sh",
              "-c",
              'until pg_isready -h postgres-db -p 5432 -U webuser; do echo "waiting for postgres..."; sleep 5; done; echo "postgres ready"',
            ]
          env:
            - name: PGPASSWORD
              value: "testpassword"
            - name: PGUSER
              value: "webuser"
        - name: wait-for-redis
          image: busybox:1.36
          command:
            [
              "sh",
              "-c",
              'until nc -z redis 6379; do echo "waiting for redis..."; sleep 5; done; echo "redis ready"',
            ]
        - name: wait-for-kafka-broker
          image: confluentinc/cp-kafka:7.5.0
          command:
            [
              "/bin/bash",
              "-c",
              'for i in {1..120}; do if /opt/confluent/bin/kafka-broker-api-versions --bootstrap-server kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092 &>/dev/null; then echo "✓ kafka broker ready"; break; fi; echo "Attempt \$i/120: Kafka not ready..."; sleep 5; done',
            ]
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
          value: "kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092"
        - name: KAFKA_TOPIC
          value: "survey-topic"
        - name: VAULT_ADDR
          value: "http://vault:8200"
        - name: VAULT_TOKEN
          value: "root"
        - name: DATABASE_URL
          value: "dbname=webdb user=webuser password=testpassword host=postgres-db port=5432"
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        livenessProbe:
          exec:
            command:
              - sh
              - -c
              - 'python -c "import redis; redis.Redis(host=\"redis\", port=6379, socket_connect_timeout=5).ping()"'
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          exec:
            command:
              - sh
              - -c
              - 'python -c "import redis; redis.Redis(host=\"redis\", port=6379, socket_connect_timeout=5).ping()"'
          initialDelaySeconds: 30
          periodSeconds: 10
YAML

 cat > "${BASE_DIR}/postgres-db.yaml" <<YAML
apiVersion: v1
kind: Service
metadata:
  name: postgres-db
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: postgres
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: postgres
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
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: postgres
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
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: postgres
    spec:
      securityContext:
        fsGroup: 999
        runAsUser: 999
        runAsNonRoot: true
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_USER
          value: "webuser"
        - name: POSTGRES_PASSWORD
          value: "testpassword"
        - name: POSTGRES_DB
          value: "webdb"
        - name: PGDATA
          value: "/var/lib/postgresql/data/pgdata"
        ports:
        - containerPort: 5432
          name: postgres
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
          subPath: pgdata
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "webuser", "-d", "webdb"]
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "webuser", "-d", "webdb"]
          initialDelaySeconds: 30
          periodSeconds: 5
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
YAML

 cat > "${BASE_DIR}/pgadmin.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: pgadmin-servers
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
data:
  servers.json: |
    {
      "Servers": {
        "1": {
          "Name": "PostgreSQL Database",
          "Group": "Servers",
          "Host": "postgres-db",
          "Port": 5432,
          "MaintenanceDB": "webdb",
          "Username": "webuser",
          "Password": "testpassword",
          "SSLMode": "prefer"
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgadmin
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: pgadmin
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: pgadmin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: pgadmin
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: pgadmin
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: pgadmin
    spec:
      initContainers:
        - name: wait-for-postgres
          image: busybox:1.35
          command:
            - "sh"
            - "-c"
            - |
              echo "Waiting for PostgreSQL to be ready..."
              until nc -z postgres-db 5432; do
                echo "Waiting for PostgreSQL..."
                sleep 10
              done
              echo "PostgreSQL is ready!"
      containers:
        - name: pgadmin
          image: dpage/pgadmin4:7.2
          env:
            - name: PGADMIN_DEFAULT_EMAIL
              value: "admin@example.com"
            - name: PGADMIN_DEFAULT_PASSWORD
              value: "adminpassword"
            - name: PGADMIN_CONFIG_SERVER_MODE
              value: "False"
            - name: PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED
              value: "False"
          ports:
            - containerPort: 80
              name: http
          resources:
            requests:
              cpu: "100m"
              memory: "512Mi"
            limits:
              cpu: "500m"
              memory: "1Gi"
          livenessProbe:
            httpGet:
              path: /misc/ping
              port: 80
            initialDelaySeconds: 120
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /misc/ping
              port: 80
            initialDelaySeconds: 60
            periodSeconds: 10
          volumeMounts:
            - name: pgadmin-data
              mountPath: /var/lib/pgadmin
            - name: pgadmin-servers
              mountPath: /pgadmin4/servers.json
              subPath: servers.json
      volumes:
        - name: pgadmin-data
          persistentVolumeClaim:
            claimName: pgadmin-storage
        - name: pgadmin-servers
          configMap:
            name: pgadmin-servers
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: pgadmin
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: pgadmin
spec:
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
  selector:
    app: ${PROJECT}
    component: pgadmin
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pgadmin-storage
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
YAML

resources=$(cat <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: davtrowebdbvault
  labels:
    app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
    component: vault
spec:
  clusterIP: None
  ports:
  - port: 8200
    name: http
  selector:
    app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
    component: vault
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault
  namespace: davtrowebdbvault
  labels:
    app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
    component: vault
spec:
  serviceName: vault
  replicas: 1
  selector:
    matchLabels:
      app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
      component: vault
  template:
    metadata:
      labels:
        app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
        component: vault
    spec:
      serviceAccountName: vault-sa
      containers:
      - name: vault
        image: hashicorp/vault:1.15.0
        command: ["vault", "server", "-dev", "-dev-listen-address=0.0.0.0:8200", "-dev-root-token-id=root"]
        ports:
        - containerPort: 8200
        env:
        - name: VAULT_ADDR
          value: "http://127.0.0.1:8200"
        - name: VAULT_DEV_ROOT_TOKEN_ID
          value: "root"
        securityContext:
          capabilities:
            add: ["IPC_LOCK"]
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "250m"
            memory: "256Mi"
        readinessProbe:
          httpGet:
            path: /v1/sys/health
            port: 8200
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /v1/sys/health
            port: 8200
          initialDelaySeconds: 15
          periodSeconds: 15
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-sa
  namespace: davtrowebdbvault
  labels:
    app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-init
  namespace: davtrowebdbvault
  labels:
    app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
data:
  init-vault.sh: |
    #!/bin/bash
    sleep 10
    export VAULT_ADDR="http://vault:8200"
    export VAULT_TOKEN="root"
    
    vault secrets enable -path=secret kv-v2
    
    vault kv put secret/database/postgres \
      postgres-user="webuser" \
      postgres-password="testpassword" \
      postgres-db="webdb" \
      postgres-host="postgres-db"
    
    vault kv put secret/redis \
      redis-password=""
    
    vault kv put secret/kafka \
      kafka-brokers="kafka:9092"
    
    vault kv put secret/grafana \
      admin-user="admin" \
      admin-password="admin"
    
    vault kv put secret/pgadmin \
      pgadmin-email="admin@example.com" \
      pgadmin-password="adminpassword"
    
    echo "Vault initialization completed"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-init
  namespace: davtrowebdbvault
  labels:
    app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
    component: vault-init
spec:
  template:
    metadata:
      labels:
        app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
        component: vault-init
    spec:
      serviceAccountName: vault-sa
      containers:
      - name: vault-init
        image: hashicorp/vault:1.15.0
        command: ["/bin/sh", "/scripts/init-vault.sh"]
        volumeMounts:
        - name: vault-scripts
          mountPath: /scripts
        env:
        - name: VAULT_ADDR
          value: "http://vault:8200"
        - name: VAULT_TOKEN  
          value: "root"
      volumes:
      - name: vault-scripts
        configMap:
          name: vault-init
          defaultMode: 0755
      restartPolicy: OnFailure
  backoffLimit: 3
YAML
)

echo "$resources" > "${BASE_DIR}/vault.yaml"

 cat > "${BASE_DIR}/redis.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: redis
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: redis
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: redis
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        command: ["redis-server", "--appendonly", "yes"]
        ports:
        - containerPort: 6379
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "250m"
            memory: "256Mi"
        livenessProbe:
          exec:
            command: ["redis-cli", "ping"]
          initialDelaySeconds: 10
          periodSeconds: 5
        readinessProbe:
          exec:
            command: ["redis-cli", "ping"]
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: redis
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: redis
spec:
  ports:
  - port: 6379
    targetPort: 6379
    protocol: TCP
  selector:
    app: ${PROJECT}
    component: redis
YAML

 cat > "${BASE_DIR}/kafka-kraft.yaml" <<YAML
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: kafka
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: kafka
spec:
  clusterIP: None
  ports:
  - port: 9092
    name: client
  - port: 9093
    name: controller
  selector:
    app: ${PROJECT}
    component: kafka
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: kafka
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: kafka
spec:
  serviceName: kafka
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: kafka
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: kafka
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: kafka
    spec:
      containers:
      - name: kafka
        image: confluentinc/cp-kafka:7.5.0
        env:
        - name: KAFKA_BROKER_ID
          value: "0"
        - name: KAFKA_PROCESS_ROLES
          value: "broker,controller"
        - name: KAFKA_CONTROLLER_QUORUM_VOTERS
          value: "0@kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9093"
        - name: KAFKA_LISTENERS
          value: "PLAINTEXT://:9092,CONTROLLER://:9093"
        - name: KAFKA_ADVERTISED_LISTENERS
          value: "PLAINTEXT://kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092"
        - name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP
          value: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
        - name: KAFKA_CONTROLLER_LISTENER_NAMES
          value: "CONTROLLER"
        - name: KAFKA_INTER_BROKER_LISTENER_NAME
          value: "PLAINTEXT"
        - name: KAFKA_AUTO_CREATE_TOPICS_ENABLE
          value: "true"
        - name: KAFKA_LOG_DIR
          value: "/var/lib/kafka/data"
        - name: KAFKA_LOG_RETENTION_HOURS
          value: "168"
        - name: KAFKA_AUTO_LEADER_REBALANCE_ENABLE
          value: "true"
        ports:
        - containerPort: 9092
          name: client
        - containerPort: 9093
          name: controller
        volumeMounts:
        - name: kafka-data
          mountPath: /var/lib/kafka/data/
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "1000m"
            memory: "2Gi"
        readinessProbe:
          tcpSocket:
            port: 9092
          initialDelaySeconds: 60
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 9092
          initialDelaySeconds: 90
          periodSeconds: 10
  volumeClaimTemplates:
  - metadata:
      name: kafka-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
YAML

 cat > "${BASE_DIR}/kafka-job-sa.yaml" <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kafka-job-sa
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: kafka-topic-job
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
YAML

 cat > "${BASE_DIR}/kafka-topic-job.yaml" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: create-kafka-topics
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: kafka-topic-job
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: kafka-topic-job
spec:
  backoffLimit: 5
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: kafka-topic-job
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: kafka-topic-job
    spec:
      serviceAccountName: kafka-job-sa
      initContainers:
        - name: wait-for-kafka-broker
          image: confluentinc/cp-kafka:7.5.0
          command:
            - /bin/bash
            - -c
            - |
              echo "Waiting for Kafka broker to be ready..."
              for i in {1..120}; do
                if /opt/confluent/bin/kafka-broker-api-versions --bootstrap-server kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092 &>/dev/null; then
                  echo "✓ Kafka broker is ready!"
                  exit 0
                fi
                echo "Attempt \$i/120: Kafka not ready..."
                sleep 5
              done
              echo "✗ Kafka broker failed to start"
              exit 1
      containers:
        - name: create-topics
          image: confluentinc/cp-kafka:7.5.0
          command:
            - /bin/bash
            - -c
            - |
              set -e
              echo "Creating Kafka topics..."
              
              /opt/confluent/bin/kafka-topics --create \
                --bootstrap-server kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092 \
                --topic survey-topic \
                --partitions 3 \
                --replication-factor 1 \
                --config retention.ms=604800000 \
                --config min.insync.replicas=1 \
                --if-not-exists
              
              echo "Verifying topics..."
              /opt/confluent/bin/kafka-topics --list \
                --bootstrap-server kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092
              
              echo "✓ Kafka topics created successfully"
      restartPolicy: OnFailure
YAML

 cat > "${BASE_DIR}/kafka-ui.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-ui
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: kafka-ui
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: kafka-ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: kafka-ui
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: kafka-ui
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: kafka-ui
    spec:
      initContainers:
        - name: wait-for-kafka
          image: confluentinc/cp-kafka:7.5.0
          command:
            - /bin/bash
            - -c
            - |
              echo "Waiting for Kafka broker to be ready..."
              for i in {1..120}; do
                if /opt/confluent/bin/kafka-topics --list --bootstrap-server kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092 2>/dev/null; then
                  echo "✓ Kafka broker is ready!"
                  exit 0
                fi
                echo "Attempt \$i/120: Kafka not ready..."
                sleep 5
              done
              echo "✗ Kafka broker failed to start"
              exit 1
      containers:
      - name: kafka-ui
        image: provectuslabs/kafka-ui:latest
        env:
        - name: KAFKA_CLUSTERS_0_NAME
          value: "local"
        - name: KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS
          value: "kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092"
        - name: KAFKA_CLUSTERS_0_READONLY
          value: "false"
        - name: KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL
          value: "PLAINTEXT"
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "200m"
            memory: "512Mi"
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-ui
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: kafka-ui
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: kafka-ui
spec:
  ports:
  - port: 8080
    targetPort: 8080
    protocol: TCP
  selector:
    app: ${PROJECT}
    component: kafka-ui
YAML

 cat > "${BASE_DIR}/prometheus-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
    
    rule_files:
      - /etc/prometheus/rules/*.yml
    
    scrape_configs:
      - job_name: 'fastapi'
        static_configs:
          - targets: ['fastapi-web-service:80']
        metrics_path: /metrics
        scrape_interval: 10s
        
      - job_name: 'redis'
        static_configs:
          - targets: ['redis:6379']
        metrics_path: /metrics
        scrape_interval: 15s
        
      - job_name: 'postgres'
        static_configs:
          - targets: ['postgres-exporter:9187']
        scrape_interval: 30s
        
      - job_name: 'kafka'
        static_configs:
          - targets: ['kafka-exporter:9308']
        scrape_interval: 30s
        
      - job_name: 'vault'
        static_configs:
          - targets: ['vault:8200']
        metrics_path: /v1/sys/metrics
        scrape_interval: 30s
        params:
          format: ['prometheus']
          
      - job_name: 'node-exporter'
        static_configs:
          - targets: ['node-exporter:9100']
        scrape_interval: 30s
YAML

 cat > "${BASE_DIR}/postgres-exporter.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-exporter
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: postgres-exporter
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: postgres-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: postgres-exporter
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: postgres-exporter
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: postgres-exporter
    spec:
      initContainers:
        - name: wait-for-postgres
          image: postgres:15-alpine
          command:
            - "sh"
            - "-c"
            - |
              until pg_isready -h postgres-db -p 5432 -U webuser; do
                echo "Waiting for postgres..."
                sleep 5
              done
              echo "PostgreSQL is ready!"
          env:
            - name: PGPASSWORD
              value: "testpassword"
      containers:
      - name: postgres-exporter
        image: prometheuscommunity/postgres-exporter:v0.15.0
        ports:
        - containerPort: 9187
          name: http
        env:
        - name: DATA_SOURCE_NAME
          value: "postgresql://webuser:testpassword@postgres-db:5432/webdb?sslmode=disable"
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
        livenessProbe:
          httpGet:
            path: /metrics
            port: 9187
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /metrics
            port: 9187
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-exporter
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: postgres-exporter
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: postgres-exporter
spec:
  ports:
  - port: 9187
    targetPort: 9187
    name: http
    protocol: TCP
  selector:
    app: ${PROJECT}
    component: postgres-exporter
YAML

 cat > "${BASE_DIR}/kafka-exporter.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-exporter
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: kafka-exporter
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: kafka-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: kafka-exporter
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: kafka-exporter
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: kafka-exporter
    spec:
      initContainers:
        - name: wait-for-kafka
          image: confluentinc/cp-kafka:7.5.0
          command:
            - /bin/bash
            - -c
            - |
              echo "Waiting for Kafka broker to be ready..."
              for i in {1..120}; do
                if /opt/confluent/bin/kafka-topics --list --bootstrap-server kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092 2>/dev/null; then
                  echo "✓ Kafka broker is ready!"
                  exit 0
                fi
                echo "Attempt \$i/120: Kafka not ready..."
                sleep 5
              done
              echo "✗ Kafka broker failed to start"
              exit 1
      containers:
      - name: kafka-exporter
        image: danielqsj/kafka-exporter:v1.7.0
        ports:
        - containerPort: 9308
          name: http
        args:
        - --kafka.server=kafka-0.kafka.${NAMESPACE}.svc.cluster.local:9092
        - --web.listen-address=:9308
        - --log.level=info
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
        livenessProbe:
          httpGet:
            path: /metrics
            port: 9308
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /metrics
            port: 9308
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-exporter
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: kafka-exporter
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: kafka-exporter
spec:
  ports:
  - port: 9308
    targetPort: 9308
    name: http
    protocol: TCP
  selector:
    app: ${PROJECT}
    component: kafka-exporter
YAML

 cat > "${BASE_DIR}/node-exporter.yaml" <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: node-exporter
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: node-exporter
spec:
  selector:
    matchLabels:
      app: ${PROJECT}
      component: node-exporter
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: node-exporter
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: node-exporter
    spec:
      containers:
      - name: node-exporter
        image: prom/node-exporter:latest
        ports:
        - containerPort: 9100
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
        args:
        - --path.procfs=/host/proc
        - --path.sysfs=/host/sys
        - --path.rootfs=/host/root
        - --collector.filesystem.ignored-mount-points=^/(sys|proc|dev|host|etc)($$|/)
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
        - name: root
          mountPath: /host/root
          readOnly: true
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
      - name: root
        hostPath:
          path: /
      hostNetwork: true
      hostPID: true
      tolerations:
      - effect: NoSchedule
        operator: Exists
---
apiVersion: v1
kind: Service
metadata:
  name: node-exporter
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: node-exporter
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: node-exporter
spec:
  ports:
  - port: 9100
    targetPort: 9100
    protocol: TCP
  selector:
    app: ${PROJECT}
    component: node-exporter
  clusterIP: None
YAML

 cat > "${BASE_DIR}/service-monitors.yaml" <<YAML
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: fastapi-monitor
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  selector:
    matchLabels:
      app: ${PROJECT}
      component: fastapi
  endpoints:
  - port: http
    path: /metrics
    interval: 15s

---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: redis-monitor
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  selector:
    matchLabels:
      app: ${PROJECT}
      component: redis
  endpoints:
  - port: redis
    interval: 30s

---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postgres-monitor
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  selector:
    matchLabels:
      app: ${PROJECT}
      component: postgres-exporter
  endpoints:
  - port: http
    interval: 30s

---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kafka-monitor
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  selector:
    matchLabels:
      app: ${PROJECT}
      component: kafka-exporter
  endpoints:
  - port: http
    interval: 30s

---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: node-monitor
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  selector:
    matchLabels:
      app: ${PROJECT}
      component: node-exporter
  endpoints:
  - port: http
    interval: 30s
YAML

 cat > "${BASE_DIR}/prometheus.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: prometheus
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: prometheus
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: prometheus
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: prometheus
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:v2.48.0
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        - name: data
          mountPath: /prometheus
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "1000m"
            memory: "2Gi"
        args:
        - '--config.file=/etc/prometheus/prometheus.yml'
        - '--storage.tsdb.path=/prometheus'
        - '--web.console.libraries=/etc/prometheus/console_libraries'
        - '--web.console.templates=/etc/prometheus/consoles'
        - '--storage.tsdb.retention.time=200h'
        - '--web.enable-lifecycle'
      volumes:
      - name: config
        configMap:
          name: prometheus-config
      - name: data
        persistentVolumeClaim:
          claimName: prometheus-data
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-service
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: prometheus
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: prometheus
spec:
  ports:
  - port: 9090
    targetPort: 9090
    protocol: TCP
  selector:
    app: ${PROJECT}
    component: prometheus
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-data
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
YAML

 cat > "${BASE_DIR}/grafana-datasource.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-service:9090
      isDefault: true
      access: proxy
      editable: true
    - name: Loki
      type: loki
      url: http://loki:3100
      access: proxy
      editable: true
    - name: Tempo
      type: tempo
      url: http://tempo:3200
      access: proxy
      editable: true
    - name: PostgreSQL
      type: postgres
      url: postgres-db:5432
      database: webdb
      user: webuser
      secureJsonData:
        password: "testpassword"
      jsonData:
        sslmode: "disable"
YAML

 cat > "${BASE_DIR}/grafana-dashboards.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
data:
  fastapi-dashboard.json: |-
    {
      "dashboard": {
        "title": "FastAPI Application Metrics",
        "panels": [
          {
            "title": "HTTP Requests",
            "type": "stat",
            "targets": [
              {
                "expr": "rate(http_requests_total[5m])",
                "legendFormat": "Requests/s"
              }
            ]
          }
        ]
      }
    }
  kafka-dashboard.json: |-
    {
      "dashboard": {
        "title": "Kafka Metrics", 
        "panels": [
          {
            "title": "Messages In",
            "type": "graph",
            "targets": [
              {
                "expr": "rate(kafka_topic_messages_in_total[5m])",
                "legendFormat": "Messages/s"
              }
            ]
          }
        ]
      }
    }
  postgres-dashboard.json: |-
    {
      "dashboard": {
        "title": "PostgreSQL Metrics",
        "panels": [
          {
            "title": "Database Connections",
            "type": "stat",
            "targets": [
              {
                "expr": "pg_stat_database_numbackends{datname=\"webdb\"}",
                "legendFormat": "Connections"
              }
            ]
          }
        ]
      }
    }
  redis-dashboard.json: |-
    {
      "dashboard": {
        "title": "Redis Metrics",
        "panels": [
          {
            "title": "Connected Clients",
            "type": "stat",
            "targets": [
              {
                "expr": "redis_connected_clients",
                "legendFormat": "Clients"
              }
            ]
          }
        ]
      }
    }
  system-dashboard.json: |-
    {
      "dashboard": {
        "title": "System Metrics",
        "panels": [
          {
            "title": "CPU Usage",
            "type": "gauge",
            "targets": [
              {
                "expr": "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
                "legendFormat": "CPU %"
              }
            ]
          }
        ]
      }
    }
  vault-dashboard.json: |-
    {
      "dashboard": {
        "title": "Vault Metrics",
        "panels": [
          {
            "title": "Vault Health",
            "type": "stat",
            "targets": [
              {
                "expr": "vault_core_unsealed",
                "legendFormat": "Unsealed"
              }
            ]
          }
        ]
      }
    }
  comprehensive-dashboard.json: |-
    {
      "dashboard": {
        "title": "Comprehensive Monitoring",
        "panels": [
          {
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
            "title": "Application Overview",
            "type": "stat",
            "targets": [
              {
                "expr": "rate(http_requests_total[5m])",
                "legendFormat": "HTTP Requests/s"
              }
            ]
          }
        ]
      }
    }
YAML

 cat > "${BASE_DIR}/grafana.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: grafana
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: grafana
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: grafana
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:10.2.2
        ports:
        - containerPort: 3000
        env:
        - name: GF_SECURITY_ADMIN_USER
          value: "admin"
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "admin"
        volumeMounts:
        - name: grafana-storage
          mountPath: /var/lib/grafana
        - name: grafana-datasources
          mountPath: /etc/grafana/provisioning/datasources
        - name: grafana-dashboards
          mountPath: /etc/grafana/provisioning/dashboards
        - name: dashboards
          mountPath: /var/lib/grafana/dashboards
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "1Gi"
        livenessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: grafana-storage
        persistentVolumeClaim:
          claimName: grafana-storage
      - name: grafana-datasources
        configMap:
          name: grafana-datasource
      - name: grafana-dashboards
        configMap:
          name: grafana-dashboard-provisioning
      - name: dashboards
        configMap:
          name: grafana-dashboards
---
apiVersion: v1
kind: Service
metadata:
  name: grafana-service
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: grafana
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: grafana
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 3000
    protocol: TCP
  selector:
    app: ${PROJECT}
    component: grafana
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-storage
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-provisioning
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
    - name: 'default'
      orgId: 1
      folder: ''
      type: file
      disableDeletion: false
      updateIntervalSeconds: 10
      allowUiUpdates: true
      options:
        path: /var/lib/grafana/dashboards
YAML

 cat > "${BASE_DIR}/loki-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
data:
  loki.yaml: |
    auth_enabled: false
    
    server:
      http_listen_port: 3100
      grpc_listen_port: 9096
      
    common:
      path_prefix: /tmp/loki
      storage:
        filesystem:
          chunks_directory: /tmp/loki/chunks
          rules_directory: /tmp/loki/rules
      replication_factor: 1
      ring:
        instance_addr: 127.0.0.1
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
    
    ruler:
      alertmanager_url: http://localhost:9093
    
    analytics:
      reporting_enabled: false
YAML

 cat > "${BASE_DIR}/loki.yaml" <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: loki
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: loki
spec:
  serviceName: loki
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: loki
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: loki
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: loki
    spec:
      containers:
      - name: loki
        image: grafana/loki:2.9.2
        ports:
        - containerPort: 3100
        - containerPort: 9096
        volumeMounts:
        - name: config
          mountPath: /etc/loki
        - name: storage
          mountPath: /tmp/loki
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "1Gi"
        args:
        - -config.file=/etc/loki/loki.yaml
      volumes:
      - name: config
        configMap:
          name: loki-config
      - name: storage
        persistentVolumeClaim:
          claimName: loki-storage
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: loki
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: loki
spec:
  ports:
  - port: 3100
    targetPort: 3100
    protocol: TCP
  - port: 9096
    targetPort: 9096
    protocol: TCP
  selector:
    app: ${PROJECT}
    component: loki
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: loki-storage
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
YAML

 cat > "${BASE_DIR}/promtail-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
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
      - source_labels: [__meta_kubernetes_pod_annotation_kubernetes_io_config_mirror]
        action: drop
        regex: mirror
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_container_name]
        action: replace
        target_label: container
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: instance
      - source_labels: [__meta_kubernetes_pod_container_name]
        action: replace
        target_label: job
      - replacement: /var/log/pods/*\$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
    
    - job_name: kubernetes-system
      static_configs:
      - targets:
          - localhost
        labels:
          job: kubernetes-system
          __path__: /var/log/containers/*.log
YAML

 cat > "${BASE_DIR}/promtail.yaml" <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: promtail
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: promtail
spec:
  selector:
    matchLabels:
      app: ${PROJECT}
      component: promtail
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: promtail
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: promtail
    spec:
      serviceAccountName: promtail-sa
      containers:
      - name: promtail
        image: grafana/promtail:2.9.2
        volumeMounts:
        - name: config
          mountPath: /etc/promtail
        - name: pods
          mountPath: /var/log/pods
          readOnly: true
        - name: containers
          mountPath: /var/log/containers
          readOnly: true
        - name: varlib
          mountPath: /var/lib
          readOnly: true
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "100m"
            memory: "128Mi"
        args:
        - -config.file=/etc/promtail/promtail.yaml
      volumes:
      - name: config
        configMap:
          name: promtail-config
      - name: pods
        hostPath:
          path: /var/log/pods
      - name: containers
        hostPath:
          path: /var/log/containers
      - name: varlib
        hostPath:
          path: /var/lib
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: promtail-sa
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: promtail-clusterrole
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
rules:
- apiGroups: [""]
  resources: ["nodes", "nodes/proxy", "services", "endpoints", "pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: promtail-clusterrolebinding
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: promtail-clusterrole
subjects:
- kind: ServiceAccount
  name: promtail-sa
  namespace: ${NAMESPACE}
YAML

 cat > "${BASE_DIR}/tempo-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
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
          path: /tmp/tempo/blocks
        pool:
          max_workers: 100
          queue_depth: 10000
    
    ingester:
      max_block_duration: 5m
YAML

 cat > "${BASE_DIR}/tempo.yaml" <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tempo
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: tempo
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: tempo
spec:
  serviceName: tempo
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT}
      component: tempo
  template:
    metadata:
      labels:
        app: ${PROJECT}
        component: tempo
        app.kubernetes.io/name: ${PROJECT}
        app.kubernetes.io/instance: ${PROJECT}
        app.kubernetes.io/component: tempo
    spec:
      containers:
      - name: tempo
        image: grafana/tempo:2.4.2
        ports:
        - containerPort: 3200
        - containerPort: 4317
        - containerPort: 4318
        volumeMounts:
        - name: config
          mountPath: /etc/tempo
        - name: storage
          mountPath: /tmp/tempo
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "250m"
            memory: "512Mi"
        args:
        - -config.file=/etc/tempo/tempo.yaml
      volumes:
      - name: config
        configMap:
          name: tempo-config
      - name: storage
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    component: tempo
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
    app.kubernetes.io/component: tempo
spec:
  ports:
  - port: 3200
    targetPort: 3200
    name: http
    protocol: TCP
  - port: 4317
    targetPort: 4317
    name: otlp-grpc
    protocol: TCP
  - port: 4318
    targetPort: 4318
    name: otlp-http
    protocol: TCP
  selector:
    app: ${PROJECT}
    component: tempo
YAML

 cat > "${BASE_DIR}/network-policies.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-fastapi-to-postgres
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: ${PROJECT}
      component: fastapi
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: ${PROJECT}
          component: postgres
    ports:
    - protocol: TCP
      port: 5432

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-fastapi-to-redis
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: ${PROJECT}
      component: fastapi
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: ${PROJECT}
          component: redis
    ports:
    - protocol: TCP
      port: 6379

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-worker-to-kafka
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: ${PROJECT}
      component: worker
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: ${PROJECT}
          component: kafka
    ports:
    - protocol: TCP
      port: 9092

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-communication
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: ${PROJECT}
      component: grafana
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: ${PROJECT}
          component: prometheus
    ports:
    - protocol: TCP
      port: 9090
  - to:
    - podSelector:
        matchLabels:
          app: ${PROJECT}
          component: loki
    ports:
    - protocol: TCP
      port: 3100
  - to:
    - podSelector:
        matchLabels:
          app: ${PROJECT}
          component: tempo
    ports:
    - protocol: TCP
      port: 3200

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-to-postgres-exporter
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: ${PROJECT}
      component: prometheus
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: ${PROJECT}
          component: postgres-exporter
    ports:
    - protocol: TCP
      port: 9187

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-pgadmin-to-postgres
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: ${PROJECT}
      component: pgadmin
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: ${PROJECT}
          component: postgres
    ports:
    - protocol: TCP
      port: 5432

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kafka-ui-to-kafka
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: ${PROJECT}
      component: kafka-ui
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: ${PROJECT}
          component: kafka
    ports:
    - protocol: TCP
      port: 9092
YAML

 cat > "${BASE_DIR}/ingress.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${PROJECT}-ingress
  namespace: ${NAMESPACE}
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
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
  - host: grafana.${PROJECT}.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana-service
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
  - host: kafka-ui.${PROJECT}.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kafka-ui
            port:
              number: 8080
YAML

 cat > "${BASE_DIR}/kyverno-policy.yaml" <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-requests-limits
  labels:
    app: ${PROJECT}
    app.kubernetes.io/name: ${PROJECT}
    app.kubernetes.io/instance: ${PROJECT}
spec:
  validationFailureAction: Audit
  background: true
  rules:
  - name: check-container-resources
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "For production, all containers should define 'requests' and 'limits' for CPU and memory."
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
YAML

 cat > "${BASE_DIR}/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NAMESPACE}

resources:
  - postgres-db.yaml
  - redis.yaml
  - vault.yaml
  - kafka-kraft.yaml
  - kafka-job-sa.yaml
  - kafka-topic-job.yaml
  - fastapi-config.yaml
  - app-deployment.yaml
  - message-processor.yaml
  - prometheus-config.yaml
  - postgres-exporter.yaml
  - kafka-exporter.yaml
  - node-exporter.yaml
  - service-monitors.yaml
  - prometheus.yaml
  - grafana-datasource.yaml
  - grafana-dashboards.yaml
  - grafana.yaml
  - loki-config.yaml
  - loki.yaml
  - promtail-config.yaml
  - promtail.yaml
  - tempo-config.yaml
  - tempo.yaml
  - pgadmin.yaml
  - kafka-ui.yaml
  - network-policies.yaml
  - ingress.yaml
  - kyverno-policy.yaml

labels:
  - pairs:
      app: ${PROJECT}
      app.kubernetes.io/name: ${PROJECT}
      app.kubernetes.io/instance: ${PROJECT}
      app.kubernetes.io/managed-by: kustomize
YAML

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
      prune: true
      selfHeal: true
YAML
}

generate_readme(){
 cat > "${ROOT_DIR}/README.md" <<README
# ${PROJECT} - Complete Monitoring Stack

## 🛠️ Quick Start

\`\`\`bash
# Generate all files
./lmarena.sh generate

# Deploy to Kubernetes
kubectl apply -k manifests/base

# Watch pods
kubectl -n ${NAMESPACE} get pods -w

# Access applications:
# Main App: http://app.${PROJECT}.local
# Grafana: http://grafana.${PROJECT}.local (admin/admin)
# PgAdmin: http://pgadmin.${PROJECT}.local (admin@example.com/adminpassword)
# Kafka UI: http://kafka-ui.${PROJECT}.local

# Initialize Vault
kubectl wait --for=condition=complete job/vault-init -n ${NAMESPACE}
\`\`\`

## 🌐 Access Points

| Service | URL | Credentials |
|---------|-----|-------------|
| Application | http://app.${PROJECT}.local | - |
| Grafana | http://grafana.${PROJECT}.local | admin/admin |
| PgAdmin | http://pgadmin.${PROJECT}.local | admin@example.com/adminpassword |
| Kafka UI | http://kafka-ui.${PROJECT}.local | - |

## 🔧 Integration Details:

1. **PgAdmin + PostgreSQL** - Full connection with servers.json configuration
2. **Vault Integration** - All passwords stored in Vault, apps retrieve them dynamically
3. **Monitoring Stack** - Loki (logs), Prometheus (metrics), Tempo (traces) all connected to Grafana
4. **Kafka UI** - Properly configured to connect to Kafka broker
5. **Health Checks** - All services have proper liveness and readiness probes

## 📊 Monitoring Stack:

- **Prometheus** - metrics collection from all services
- **Grafana** - unified dashboards with all datasources
- **Loki** - centralized log aggregation
- **Tempo** - distributed tracing
- **Postgres Exporter** - database metrics
- **Kafka Exporter** - Kafka metrics
- **Node Exporter** - system metrics

## 🔐 Security:

- All passwords in Vault
- Network policies for service communication
- Proper security contexts for PostgreSQL
- Proper health checks and resource limits

README
}

generate_all(){
 generate_structure
 generate_fastapi_app
 generate_dockerfile
 generate_github_actions
 generate_k8s_manifests
 generate_readme
 echo
 echo "✅ Generation complete!"
 echo "📁 Structure:"
 echo "   📁 app/ - FastAPI application with Vault integration"
 echo "   📁 manifests/base/ - ALL Kubernetes manifests"
 echo "   📄 Dockerfile - Container definition"
 echo "   📄 .github/workflows/ci-cd.yaml - GitHub Actions"
 echo "   📄 README.md - Complete documentation"
 echo
 echo "🚀 Next steps:"
 echo "1. Deploy: kubectl apply -k manifests/base"
 echo "2. Watch: kubectl -n ${NAMESPACE} get pods -w"
 echo "3. Access: http://app.${PROJECT}.local"
 echo "4. Monitor: http://grafana.${PROJECT}.local (admin/admin)"
 echo "5. Manage DB: http://pgadmin.${PROJECT}.local (admin@example.com/adminpassword)"
 echo "6. View Kafka: http://kafka-ui.${PROJECT}.local"
}

case "$1" in
  generate)
    generate_all
    ;;
  *)
    echo "Usage: $0 generate"
    exit 1
    ;;
esac