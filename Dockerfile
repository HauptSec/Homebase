FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HOMEBASE_DB=/data/homebase.sqlite
WORKDIR /app
COPY server/requirements.txt server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt && useradd --uid 10001 --create-home homebase && mkdir /data /backups && chown homebase:homebase /data /backups
COPY --chown=homebase:homebase server server
USER homebase
EXPOSE 8080
CMD ["uvicorn", "server.app:app", "--host", "0.0.0.0", "--port", "8080", "--no-proxy-headers", "--ws-max-size", "131072", "--limit-concurrency", "100"]
