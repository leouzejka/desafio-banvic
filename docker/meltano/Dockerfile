FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir meltano==4.2.2 \
    && useradd --create-home --uid 10001 meltano

WORKDIR /opt/meltano

COPY meltano.yml ./meltano.yml
COPY meltano/ ./meltano/
COPY plugins/ ./plugins/
# Os CSVs não entram na imagem: são montados em /data/raw na execução

RUN chown -R meltano:meltano /opt/meltano \
    && su meltano -c 'meltano install'

USER meltano
