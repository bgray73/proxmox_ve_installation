# LabOps A2A Agent — layer-optimized multi-stage image
# Build:  docker build -t labops-a2a-agent .
# Run:    docker run --rm -p 9999:9999 -v labops-a2a-data:/data labops-a2a-agent
#
# Layer strategy:
#  1) Builder installs deps into a venv (cached until requirements.txt changes)
#  2) Runtime copies only the venv + app modules (no pip, no build tools)
#  3) Single RUN for OS packages + user + dirs (fewer layers / smaller image)

# -- Builder --
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --upgrade pip \
    && pip install -r requirements.txt

# -- Runtime --
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    A2A_HOST=0.0.0.0 \
    A2A_PORT=9999 \
    A2A_DB=/data/labops_a2a.db

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser \
    && mkdir -p /data \
    && chown appuser:appuser /data

COPY --from=builder --chown=appuser:appuser /opt/venv /opt/venv
COPY --chown=appuser:appuser agent_executor.py server.py ./

USER appuser

EXPOSE 9999
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9999/.well-known/agent-card.json', timeout=3)"

CMD ["python", "server.py", "--host", "0.0.0.0", "--port", "9999", "--db", "/data/labops_a2a.db"]
