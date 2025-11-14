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

# Redis and Kafka configuration
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_LIST = os.getenv("REDIS_LIST", "outgoing_messages")
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
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
            # Test connection
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
                raise e

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
        # Push to Redis for processing
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
        # Push to Redis for processing
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
