FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
EXPOSE 8081
# Datadog tracing: ddtrace-run auto-instruments FastAPI, httpx, redis ... (DD_* settings in the manifests).
CMD ["ddtrace-run", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8081", "--no-access-log"]
