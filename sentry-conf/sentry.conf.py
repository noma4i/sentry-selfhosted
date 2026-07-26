from sentry.conf.server import *  # NOQA

BYTE_MULTIPLIER = 1024
UNITS = ("K", "M", "G")


def unit_text_to_bytes(text):
    unit = text[-1].upper()
    power = UNITS.index(unit) + 1
    return float(text[:-1]) * (BYTE_MULTIPLIER**power)


def get_internal_network():
    import ctypes
    import fcntl
    import math
    import socket
    import struct

    iface = b"eth0"
    sockfd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ifreq = struct.pack(b"16sH14s", iface, socket.AF_INET, b"\x00" * 14)

    try:
        ip = struct.unpack(
            b"!I", struct.unpack(b"16sH2x4s8x", fcntl.ioctl(sockfd, 0x8915, ifreq))[2]
        )[0]
        netmask = socket.ntohl(
            struct.unpack(b"16sH2xI8x", fcntl.ioctl(sockfd, 0x891B, ifreq))[2]
        )
    except IOError:
        return ()
    base = socket.inet_ntoa(struct.pack(b"!I", ip & netmask))
    netmask_bits = 32 - int(round(math.log(ctypes.c_uint32(~netmask).value + 1, 2), 1))
    return "{0:s}/{1:d}".format(base, netmask_bits)


INTERNAL_SYSTEM_IPS = (get_internal_network(),)

DATABASES = {
    "default": {
        "ENGINE": "sentry.db.postgres",
        "NAME": "postgres",
        "USER": "postgres",
        "PASSWORD": "",
        "HOST": "pgbouncer",
        "PORT": "",
    }
}

SENTRY_SINGLE_ORGANIZATION = True

SENTRY_OPTIONS["system.event-retention-days"] = int(
    env("SENTRY_EVENT_RETENTION_DAYS", "90")
)

if env("SENTRY_SYSTEM_SECRET_KEY"):
    SENTRY_OPTIONS["system.secret-key"] = env("SENTRY_SYSTEM_SECRET_KEY", "")

SENTRY_SELF_HOSTED_ERRORS_ONLY = True
SENTRY_AIR_GAP = False

SENTRY_NODESTORE = "sentry_nodestore_s3.S3PassthroughDjangoNodeStorage"
SENTRY_NODESTORE_OPTIONS = {
    "compression": True,
    "endpoint_url": "http://seaweedfs:8333",
    "bucket_path": "nodestore",
    "bucket_name": "nodestore",
    "region_name": "us-east-1",
    "aws_access_key_id": "sentry",
    "aws_secret_access_key": "sentry",
}

SENTRY_OPTIONS["redis.clusters"] = {
    "default": {
        "hosts": {0: {"host": "redis", "password": "", "port": "6379", "db": "0"}}
    }
}

CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.redis.RedisCache",
        "LOCATION": "redis://redis:6379/1",
        "TIMEOUT": 3600,
    }
}

SENTRY_CACHE = "sentry.cache.redis.RedisCache"

DEFAULT_KAFKA_OPTIONS = {
    "bootstrap.servers": "kafka:9092",
    "message.max.bytes": 50000000,
    "socket.timeout.ms": 1000,
}

SENTRY_EVENTSTREAM = "sentry.eventstream.kafka.KafkaEventStream"
SENTRY_EVENTSTREAM_OPTIONS = {"producer_configuration": DEFAULT_KAFKA_OPTIONS}

KAFKA_CLUSTERS["default"] = DEFAULT_KAFKA_OPTIONS

SENTRY_RATELIMITER = "sentry.ratelimits.redis.RedisRateLimiter"
SENTRY_BUFFER = "sentry.buffer.redis.RedisBuffer"
SENTRY_QUOTAS = "sentry.quotas.redis.RedisQuota"
SENTRY_TSDB = "sentry.tsdb.redissnuba.RedisSnubaTSDB"

SENTRY_SEARCH = "sentry.search.snuba.EventsDatasetSnubaSearchBackend"
SENTRY_SEARCH_OPTIONS = {}
SENTRY_TAGSTORE_OPTIONS = {}

SENTRY_DIGESTS = "sentry.digests.backends.redis.RedisBackend"

SENTRY_WEB_HOST = "0.0.0.0"
SENTRY_WEB_PORT = 9000
SENTRY_WEB_OPTIONS = {
    "http": "%s:%s" % (SENTRY_WEB_HOST, SENTRY_WEB_PORT),
    "protocol": "uwsgi",
    "uwsgi-socket": None,
    "so-keepalive": True,
    "http-keepalive": 15,
    "http-chunked-input": True,
    "workers": 1,
    "threads": 2,
    "memory-report": False,
    "max-requests": 100000,
    "max-requests-delta": 500,
    "max-worker-lifetime": 86400,
    "thunder-lock": True,
    "log-x-forwarded-for": False,
    "buffer-size": 32768,
    "limit-post": 209715200,
    "disable-logging": True,
    "reload-on-rss": 900,
    "ignore-sigpipe": True,
    "ignore-write-errors": True,
    "disable-write-exception": True,
}

SENTRY_OPTIONS["mail.list-namespace"] = env("SENTRY_MAIL_HOST", "localhost")
SENTRY_OPTIONS["mail.from"] = f"sentry@{SENTRY_OPTIONS['mail.list-namespace']}"

SENTRY_FEATURES["projects:sample-events"] = False
SENTRY_FEATURES.update(
    {
        feature: True
        for feature in (
            "organizations:discover",
            "organizations:global-views",
            "organizations:issue-views",
            "organizations:incidents",
            "organizations:integrations-issue-basic",
            "organizations:integrations-issue-sync",
            "organizations:invite-members",
            "organizations:sso-basic",
            "organizations:sso-saml2",
            "organizations:advanced-search",
            "organizations:issue-platform",
            "organizations:monitors",
            "organizations:dashboards-mep",
            "organizations:mep-rollout-flag",
            "organizations:dashboards-rh-widget",
            "organizations:dynamic-sampling",
            "projects:custom-inbound-filters",
            "projects:data-forwarding",
            "projects:discard-groups",
            "projects:plugins",
            "projects:rate-limits",
            "projects:servicehooks",
        )
    }
)

GEOIP_PATH_MMDB = "/geoip/GeoLite2-City.mmdb"
CSP_REPORT_ONLY = True
JS_SDK_LOADER_DEFAULT_SDK_URL = "https://browser.sentry-cdn.com/%s/bundle%s.min.js"

_public_url = env("SENTRY_PUBLIC_URL", "")
if _public_url:
    CSRF_TRUSTED_ORIGINS = [_public_url]
    SENTRY_OPTIONS["system.url-prefix"] = _public_url


SENTRY_FEATURES['integrations-scm-multi-org'] = True
SENTRY_FEATURES['organizations:integrations-scm-multi-org'] = True
SENTRY_FEATURES['organizations:github-multi-org-upsell-modal'] = True
