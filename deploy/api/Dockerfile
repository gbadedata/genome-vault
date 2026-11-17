# genome-vault API: FastAPI on Cloud Run, reading BigQuery.
# Only the API package goes in the image; the loader and its VCF libraries
# (cyvcf2, pysam, numpy) are not needed to serve queries.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPATH=/app/src \
    PORT=8080

WORKDIR /app
COPY deploy/api/requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt

COPY src/genome_vault/__init__.py /app/src/genome_vault/__init__.py
COPY src/genome_vault/api /app/src/genome_vault/api

RUN useradd --create-home --uid 10001 app
USER 10001
EXPOSE 8080

# One worker: the rate limiter, cache and daily budget live in this process,
# and Cloud Run runs at most one instance.
CMD ["sh", "-c", "exec uvicorn genome_vault.api.app:app --host 0.0.0.0 --port ${PORT} --workers 1"]
