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
