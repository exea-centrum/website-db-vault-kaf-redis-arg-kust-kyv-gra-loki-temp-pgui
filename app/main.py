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
    uvicorn.run("main:app", host="0.0.0.0", port=int(os.getenv("PORT", "8000")))
