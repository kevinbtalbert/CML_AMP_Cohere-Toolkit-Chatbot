# Use Cloudera image as the base
FROM docker.repository.cloudera.com/cloudera/cdsw/ml-runtime-jupyterlab-python3.11-cuda:2024.05.1-b8 AS cloudera-base

# Use Terrarium image
FROM ghcr.io/cohere-ai/terrarium:latest as terrarium

# Create a new layer from Python
FROM python:3.11

USER root

# Upgrade packages in the base image
RUN apt-get update && apt-get upgrade -y && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set environment variables
ENV ML_RUNTIME_EDITION="ML Runtime with JupyterLab Edition" \
    ML_RUNTIME_SHORT_VERSION="1" \
    ML_RUNTIME_MAINTENANCE_VERSION="0" \
    ML_RUNTIME_FULL_VERSION="1.0" \
    ML_RUNTIME_DESCRIPTION="ML Runtime to accompany Cohere Toolkit"

LABEL com.cloudera.ml.runtime.edition=$ML_RUNTIME_EDITION \
      com.cloudera.ml.runtime.full-version=$ML_RUNTIME_FULL_VERSION \
      com.cloudera.ml.runtime.short-version=$ML_RUNTIME_SHORT_VERSION \
      com.cloudera.ml.runtime.maintenance-version=$ML_RUNTIME_MAINTENANCE_VERSION \
      com.cloudera.ml.runtime.description=$ML_RUNTIME_DESCRIPTION \
      authors="Cohere"

ENV PG_APP_HOME=/etc/docker-app
ENV PYTHON_VERSION=3.11.8
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PYTHONIOENCODING=utf-8
ENV LANG C.UTF-8
ENV PYTHONPATH=/workspace/src/
ENV VIRTUAL_ENV=/workspace/.venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
ENV POETRY_VIRTUALENVS_IN_PROJECT=true

# Copy entrypoint script
COPY docker_scripts/gcp-entrypoint.sh /sbin/gcp-entrypoint.sh

RUN chmod 755 /sbin/gcp-entrypoint.sh \
    && curl -sL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get update \
    && apt-get install --no-install-recommends -y nginx nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && npm install -g pnpm \
    && npm install -g pm2

# Copy nginx config
COPY docker_scripts/nginx.conf /etc/nginx/nginx.conf

WORKDIR /workspace

# Copy dependency files to avoid cache invalidations
COPY pyproject.toml poetry.lock ./

# Diagnostic: Check Poetry version and Python version
RUN python3 --version \
    && pip3 --version \
    && pip3 install --no-cache-dir poetry==1.6.1 \
    && poetry --version

# Install dependencies
RUN poetry config installer.max-workers 10 \
    && poetry install \
    && poetry cache clear pypi --all --no-interaction

# Copy the rest of the code
COPY src/backend src/backend
COPY docker_scripts/ ${PG_APP_HOME}/

# Install frontend dependencies
WORKDIR /workspace/src/interfaces/coral_web
COPY src/interfaces/coral_web/src ./src
COPY src/interfaces/coral_web/public ./public
COPY src/interfaces/coral_web/next.config.mjs .
COPY src/interfaces/coral_web/tsconfig.json .
COPY src/interfaces/coral_web/tailwind.config.js .
COPY src/interfaces/coral_web/postcss.config.js .
COPY src/interfaces/coral_web/package.json src/interfaces/coral_web/yarn.lock* src/interfaces/coral_web/package-lock.json* src/interfaces/coral_web/pnpm-lock.yaml* ./
COPY src/interfaces/coral_web/.env.development .
COPY src/interfaces/coral_web/.env.production .

ENV NEXT_PUBLIC_API_HOSTNAME='/api'
RUN npm install \
    && npm run next:build

# Copy Terrarium files
WORKDIR /usr/src/app
COPY --from=terrarium /usr/src/app/package*.json ./
RUN npm install -g ts-node \
    && npm install \
    && npm prune --production
COPY --from=terrarium /usr/src/app/. .
ENV ENV_RUN_AS "docker"

# Ports to expose
EXPOSE 4000/tcp
EXPOSE 8000/tcp
EXPOSE 8090/tcp

CMD ["/sbin/gcp-entrypoint.sh"]