FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates tar \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir -r requirements.txt

# Install Pixlet v0.34.0 for linux amd64
RUN set -eux; \
    curl -fsSL -o /tmp/pixlet.tgz "https://github.com/tidbyt/pixlet/releases/download/v0.34.0/pixlet_0.34.0_linux_amd64.tar.gz"; \
    tar -xzf /tmp/pixlet.tgz -C /usr/local/bin pixlet; \
    chmod +x /usr/local/bin/pixlet; \
    /usr/local/bin/pixlet --version || true; \
    rm -f /tmp/pixlet.tgz

COPY get_weather_data.py .
COPY tidbyt /app/tidbyt

RUN mkdir -p /app/cache

CMD ["python", "-u", "get_weather_data.py"]
