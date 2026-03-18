# Stage 1: Build frontend and generate static assets
FROM python:3.13.1-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gcc g++ make libpcre2-dev zlib1g-dev git \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 24.x
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && corepack enable \
    && corepack prepare pnpm@10.30.2 --activate

# Install uv for Python dependency management
RUN pip install --no-cache-dir 'uv==0.9.28'

WORKDIR /build

# Copy dependency files first for layer caching
COPY pyproject.toml uv.lock package.json pnpm-lock.yaml .node-version .npmrc ./

# Setup Python venv and install dependencies
RUN python3 -m venv /.venv
ENV PATH="/.venv/bin:$PATH" UV_PROJECT_ENVIRONMENT=/.venv \
    PIP_NO_CACHE_DIR=1 UV_COMPILE_BYTECODE=1 UV_NO_CACHE=1

RUN uv sync --frozen --quiet --no-install-project

# Install JS dependencies (need devDependencies for build)
RUN pnpm install --frozen-lockfile

# Copy full source
COPY . .

# Build step 1: fast_editable
RUN python3 -m tools.fast_editable --path .

# Build step 2: integration docs + JS SDK registry
RUN python3 -m sentry.build._integration_docs --dest src/sentry/integration-docs \
    && python3 -m sentry.build._js_sdk_registry

# Build step 3: frontend (rspack)
# Fake git for rspack config that calls `git rev-parse HEAD`
RUN git init && git add -A && GIT_AUTHOR_NAME=build GIT_AUTHOR_EMAIL=build@local GIT_COMMITTER_NAME=build GIT_COMMITTER_EMAIL=build@local git commit -m "build" --quiet 2>/dev/null || true
ENV NODE_OPTIONS="--max-old-space-size=4096 --experimental-transform-types"
RUN pnpm run build-production \
    && pnpm run build-chartcuterie-config

# Stage 2: Production image
FROM python:3.13.1-slim-bookworm

RUN groupadd -r sentry --gid 999 && useradd -r -m -g sentry --uid 999 sentry

RUN apt-get update \
    && apt-get install -y --no-install-recommends gosu libexpat1 tini \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/sentry

ENV PATH="/.venv/bin:$PATH" UV_PROJECT_ENVIRONMENT=/.venv \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    SENTRY_CONF=/etc/sentry \
    GRPC_POLL_STRATEGY=epoll1

# Copy venv and built source from builder
COPY --from=builder /.venv /.venv
COPY --from=builder /build /usr/src/sentry

# Re-link sentry package (egg-link paths differ between build and production)
RUN python3 -m pip install --no-cache-dir 'uv==0.9.28' \
    && python3 -m tools.fast_editable --path .

# Install S3 nodestore plugin
RUN pip install https://github.com/getsentry/sentry-nodestore-s3/archive/main.zip

# Copy docker entrypoint from source
COPY self-hosted/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Copy custom configs (placed by build.sh into _overlay/)
COPY _overlay/sentry.conf.py _overlay/config.yml $SENTRY_CONF/
COPY _overlay/entrypoint.sh /etc/sentry/entrypoint.sh
RUN chmod +x /etc/sentry/entrypoint.sh

RUN mkdir -p $SENTRY_CONF \
    && sentry help | sed '1,/Commands:/d' | awk '{print $1}' > /sentry-commands.txt

EXPOSE 9000
VOLUME /data

ENTRYPOINT ["/etc/sentry/entrypoint.sh"]
CMD ["run", "web"]
