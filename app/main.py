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
from opentel-e-metry.sdk.resources import Resource
from opentel-e-metry import trace
from opentel-e-metry.sdk.trace import TracerProvider
from opentel-e-metry.sdk.trace.export import BatchSpanProcessor
from opentel-e-metry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter


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
