#!/bin/bash
set -euo pipefail

TOTAL_START=$(date +%s)
step_time() { echo "  ($(( $(date +%s) - $1 ))s)"; }

echo "=== Sentry Local Init ==="

source .env

# 1. Build all images from source
S=$(date +%s)
echo "[1/10] Building images from source..."
./build.sh
step_time $S

# 2. Start infra services
S=$(date +%s)
echo "[2/10] Starting infrastructure..."
docker compose up -d postgres redis kafka clickhouse seaweedfs smtp pgbouncer
echo "  Waiting for services to be healthy..."
sleep 25
step_time $S

# 3. Generate relay credentials if missing
S=$(date +%s)
if [ ! -f relay-conf/credentials.json ] || [ ! -s relay-conf/credentials.json ]; then
  echo "[3/10] Generating relay credentials..."
  docker run --rm --entrypoint /bin/relay "$RELAY_IMAGE" credentials generate --stdout > relay-conf/credentials.json
  echo "  Relay credentials saved"
else
  echo "[3/10] Relay credentials already exist"
fi
step_time $S

# 4. Generate secret key if not set
S=$(date +%s)
if ! grep -q SENTRY_SYSTEM_SECRET_KEY .env 2>/dev/null; then
  echo "[4/10] Generating secret key..."
  SECRET_KEY=$(docker compose run --rm web sentry config generate-secret-key 2>/dev/null | tail -1)
  echo "SENTRY_SYSTEM_SECRET_KEY=$SECRET_KEY" >> .env
  echo "  Secret key saved to .env"
else
  echo "[4/10] Secret key already exists"
fi
step_time $S

# 5. Create Kafka topics
S=$(date +%s)
echo "[5/10] Creating Kafka topics..."
SENTRY_TOPICS="ingest-events ingest-attachments ingest-transactions ingest-metrics ingest-generic-metrics ingest-replay-recordings ingest-occurrences ingest-profiles ingest-feedback-events"
for topic in $SENTRY_TOPICS; do
  docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --topic "$topic" --partitions 1 --replication-factor 1 --if-not-exists 2>/dev/null || true
done
echo "  Kafka topics ready"
step_time $S

# 6. Bootstrap Snuba (ClickHouse tables + Snuba Kafka topics)
S=$(date +%s)
echo "[6/10] Bootstrapping Snuba..."
docker compose run --rm --entrypoint bash snuba-api -c "snuba bootstrap --force"
step_time $S

# 7. Load database schema (or run migrations if schema dump not found)
S=$(date +%s)
if [ -f db/schema.sql ]; then
  echo "[7/10] Loading database schema from dump..."
  docker compose exec -T postgres psql -U postgres -d postgres < db/schema.sql > /dev/null 2>&1
  # Run post-migration steps
  docker compose run --rm web sentry upgrade --noinput 2>&1 | tail -5
else
  echo "[7/10] Running database migrations (no schema dump found)..."
  docker compose run --rm web sentry upgrade --noinput
fi
step_time $S

# 8. Create S3 buckets
S=$(date +%s)
echo "[8/10] Creating S3 buckets..."
docker compose run --rm web python3 -c "
import boto3
s3 = boto3.client('s3', endpoint_url='http://seaweedfs:8333', aws_access_key_id='sentry', aws_secret_access_key='sentry', region_name='us-east-1')
for bucket in ['nodestore', 'profiles']:
    try:
        s3.create_bucket(Bucket=bucket)
        print(f'  Created bucket: {bucket}')
    except Exception as e:
        if 'BucketAlready' in str(e):
            print(f'  Bucket exists: {bucket}')
        else:
            raise
"
step_time $S

# 9. Register relay in Sentry
S=$(date +%s)
echo "[9/10] Registering relay..."
RELAY_ID=$(python3 -c "import json; print(json.load(open('relay-conf/credentials.json'))['id'])")
RELAY_KEY=$(python3 -c "import json; print(json.load(open('relay-conf/credentials.json'))['public_key'])")
docker compose run --rm web sentry django shell -c "
from sentry.models.relay import Relay
relay, created = Relay.objects.get_or_create(
    relay_id='$RELAY_ID',
    defaults={'public_key': '$RELAY_KEY', 'is_internal': True}
)
if not created:
    relay.public_key = '$RELAY_KEY'
    relay.is_internal = True
    relay.save()
print(f'  Relay registered (created={created})')
"
step_time $S

# 10. Create admin user
S=$(date +%s)
echo "[10/10] Creating admin user..."
docker compose run --rm web sentry createuser --email admin@localhost --password admin123 --superuser --no-input 2>/dev/null || echo "  User already exists"
step_time $S

# Start everything
echo ""
echo "Starting all services..."
docker compose up -d

echo ""
echo "Waiting for services to be healthy..."
sleep 30

TOTAL=$(( $(date +%s) - TOTAL_START ))
echo ""
echo "=== Init complete in ${TOTAL}s ==="
echo ""
echo "  URL:      http://localhost:9000"
echo "  Email:    admin@localhost"
echo "  Password: admin123"
echo ""
docker compose ps --format "table {{.Name}}\t{{.Status}}"
