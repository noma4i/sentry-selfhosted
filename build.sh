#!/bin/bash
set -euo pipefail

echo "=== Building Sentry from source ==="

# 1. Build sentry base image from source
echo "[1/4] Building sentry base image (this takes ~5-10 min)..."
docker build -t sentry-base-local -f source/sentry/self-hosted/Dockerfile source/sentry

# 2. Build sentry overlay (adds S3 nodestore + custom configs)
echo "[2/4] Building sentry overlay..."
docker build -t sentry-self-hosted-local --build-arg SENTRY_IMAGE=sentry-base-local sentry-conf

# 3. Build snuba from source
echo "[3/4] Building snuba..."
docker build -t snuba-local source/snuba

# 4. Build taskbroker from source
echo "[4/4] Building taskbroker..."
docker build -t taskbroker-local source/taskbroker

echo ""
echo "=== Build complete ==="
echo "Run ./init.sh to initialize, or docker compose up -d to start"
