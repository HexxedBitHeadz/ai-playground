FROM python:3.12-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py ./
COPY templates ./templates
RUN mkdir -p /app/static/branding

RUN useradd -r -u 1001 -g root -s /usr/sbin/nologin appuser \
    && mkdir -p /logs \
    && chown -R appuser:root /app /logs
USER appuser
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
