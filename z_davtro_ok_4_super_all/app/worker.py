#!/usr/bin/env python3
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
        return KafkaProducer(
            bootstrap_servers=KAFKA_BOOTSTRAP.split(','),
            value_serializer=lambda v: json.dumps(v).encode('utf-8')
        )
    except Exception as e:
        logger.exception("Kafka init error: %s", e)
        return None

def get_db_connection():
    max_retries = 30
    for attempt in range(max_retries):
        try:
            conn = psycopg2.connect(DATABASE_URL)
            return conn
        except psycopg2.OperationalError as e:
            logger.warning(f"Attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(10)
            else:
                logger.error(f"All connection attempts failed: {e}")
                raise e

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
        # Send to Kafka
        if producer:
            producer.send(KAFKA_TOPIC, value=item)
            producer.flush()
            logger.info(f"Sent to Kafka topic {KAFKA_TOPIC}: {item}")
        
        # Save to PostgreSQL
        item_type = item.get("type")
        save_to_db(item_type, item)
        
    except Exception as e:
        logger.exception(f"Processing failed for item: {item}")

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
                    item = {"raw": data, "type": "unknown"}
                
                process_item(item, producer)
        except Exception:
            logger.exception("Worker loop exception")
            time.sleep(2)

if __name__ == "__main__":
    main()
