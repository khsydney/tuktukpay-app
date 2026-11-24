FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
# Same image, two roles (see docker-compose.yml):
# Datadog tracing: ddtrace-run auto-instruments FastAPI, httpx, redis ... (DD_* settings in the manifests).
# Datadog tracing: ddtrace-run auto-instruments FastAPI, httpx, redis ... (DD_* settings in the manifests).
CMD ["ddtrace-run", "python", "worker.py"]
