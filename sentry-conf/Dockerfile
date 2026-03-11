ARG SENTRY_IMAGE=sentry-base-local
FROM ${SENTRY_IMAGE}

RUN pip install https://github.com/getsentry/sentry-nodestore-s3/archive/main.zip

COPY . /usr/src/sentry
