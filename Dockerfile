FROM ghcr.io/astral-sh/uv:0.9.5 AS uv
FROM python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /workspace/server
COPY server/pyproject.toml server/uv.lock ./
COPY server/shelfsight ./shelfsight
RUN uv sync --frozen --no-dev
COPY app/assets/defaults.json /workspace/app/assets/defaults.json
RUN useradd --create-home --uid 10001 shelfsight
USER shelfsight
ENV SHELFSIGHT_RUNTIME_DIR=/tmp/shelfsight \
    SHELFSIGHT_CLOUD_MODE=true \
    PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["/workspace/server/.venv/bin/python", "-m", "shelfsight.cloud"]
