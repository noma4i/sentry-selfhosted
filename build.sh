#!/bin/bash
set -euo pipefail

echo "=== Building all Sentry images from source ==="

# 1. Build sentry (Python + frontend + custom configs)
echo "[1/3] Building sentry from source (Python + JS frontend)..."
echo "       This may take 10-15 minutes on the first run."

# Place custom configs into source for Docker build context
mkdir -p source/sentry/_overlay
cp sentry-conf/sentry.conf.py source/sentry/_overlay/
cp sentry-conf/config.yml source/sentry/_overlay/
cp sentry-conf/entrypoint.sh source/sentry/_overlay/

DOCKER_BUILDKIT=1 docker build --memory=6g -t sentry-self-hosted-local \
  -f sentry-conf/Dockerfile \
  source/sentry

# Clean up overlay
rm -rf source/sentry/_overlay

# 2. Build snuba from source (Python)
echo "[2/3] Building snuba from source..."
docker build -t snuba-local source/snuba

# 3. Build taskbroker from source (Rust)
echo "[3/3] Building taskbroker from source..."
docker build -t taskbroker-local source/taskbroker

echo ""
echo "=== Build complete ==="
echo ""
echo "Images built from source:"
docker images --format "  {{.Repository}}:{{.Tag}}  {{.Size}}" | grep -E "sentry-self-hosted-local|snuba-local|taskbroker-local"
echo ""
echo "Run ./init.sh to initialize, or docker compose up -d to start"
