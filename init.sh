#!/bin/bash
set -euo pipefail

echo "=== Sentry Local Init ==="

# 1. Build all images from source
echo "[1/10] Building images from source..."
./build.sh

# 2. Generate secret key if not set
if ! grep -q SENTRY_SYSTEM_SECRET_KEY .env 2>/dev/null; then
  echo "[2/10] Generating secret key..."
  SECRET_KEY=$(docker compose run --rm web sentry config generate-secret-key 2>/dev/null | tail -1)
  echo "SENTRY_SYSTEM_SECRET_KEY=$SECRET_KEY" >> .env
  echo "  Secret key saved to .env"
else
  echo "[2/10] Secret key already exists"
fi

# 3. Generate relay credentials if missing
if [ ! -f relay-conf/credentials.json ]; then
  echo "[3/10] Generating relay credentials..."
  docker compose run --rm relay credentials generate --stdout > relay-conf/credentials.json
  echo "  Relay credentials saved"
else
  echo "[3/10] Relay credentials already exist"
fi

# 4. Start infra services
echo "[4/10] Starting infrastructure..."
docker compose up -d postgres redis kafka clickhouse seaweedfs smtp pgbouncer
echo "  Waiting for services to be healthy..."
sleep 20

# 5. Create Kafka topics
echo "[5/10] Creating Kafka topics..."
SENTRY_TOPICS="ingest-events ingest-attachments ingest-transactions ingest-metrics ingest-generic-metrics ingest-replay-recordings ingest-occurrences ingest-profiles ingest-feedback-events"
for topic in $SENTRY_TOPICS; do
  docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --create --topic "$topic" --partitions 1 --replication-factor 1 --if-not-exists 2>/dev/null || true
done
echo "  Kafka topics ready"

# 6. Bootstrap Snuba (ClickHouse tables + Snuba Kafka topics)
echo "[6/10] Bootstrapping Snuba..."
docker compose run --rm --entrypoint bash snuba-api -c "snuba bootstrap --force"

# 7. Run database migrations
echo "[7/10] Running database migrations..."
docker compose run --rm web sentry upgrade --noinput

# 8. Create S3 buckets
echo "[8/10] Creating S3 buckets..."
docker compose exec web python3 -c "
import boto3
s3 = boto3.client('s3', endpoint_url='http://seaweedfs:8333', aws_access_key_id='sentry', aws_secret_access_key='sentry', region_name='us-east-1')
for bucket in ['nodestore', 'profiles']:
    try:
        s3.create_bucket(Bucket=bucket)
        print(f'  Created bucket: {bucket}')
    except s3.exceptions.BucketAlreadyExists:
        print(f'  Bucket exists: {bucket}')
    except Exception as e:
        if 'BucketAlreadyOwnedByYou' in str(e) or 'BucketAlreadyExists' in str(e):
            print(f'  Bucket exists: {bucket}')
        else:
            raise
"

# 9. Register relay in Sentry
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

# 10. Create admin user
echo "[10/10] Creating admin user..."
docker compose run --rm web sentry createuser --email admin@localhost --password admin123 --superuser --no-input 2>/dev/null || echo "  User already exists"

# Start everything
echo ""
echo "Starting all services..."
docker compose up -d

echo ""
echo "=== Init complete! ==="
echo ""
echo "  URL:      http://localhost:9000"
echo "  Email:    admin@localhost"
echo "  Password: admin123"
echo ""
echo "  Check status: docker compose ps"
echo "  Check memory: docker stats --no-stream"
