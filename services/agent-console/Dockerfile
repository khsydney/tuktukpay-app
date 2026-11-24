FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
COPY requirements.txt .
RUN pip install -r requirements.txt
# Uncomment to enable real providers: RUN pip install openai anthropic boto3
COPY . .
# Same image, two roles (see docker-compose.yml):
# Datadog tracing: ddtrace-run auto-instruments FastAPI, httpx, redis ... (DD_* settings in the manifests).
# Datadog tracing: ddtrace-run auto-instruments FastAPI, httpx, redis ... (DD_* settings in the manifests).
EXPOSE 8087 8088
CMD ["ddtrace-run", "uvicorn", "shopping_agent:app", "--host", "0.0.0.0", "--port", "8087", "--no-access-log"]
