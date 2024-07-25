# Base image
FROM ubuntu:22.04
# Use Terrarium image
FROM ghcr.io/cohere-ai/terrarium:latest as terrarium
# Final stage
FROM python:3.11

USER root

# Set environment variables
ENV ML_RUNTIME_EDITION="ML Runtime for Cohere Toolkit" \
    ML_RUNTIME_SHORT_VERSION="1" \
    ML_RUNTIME_MAINTENANCE_VERSION="7" \
    ML_RUNTIME_FULL_VERSION="2024.07.7" \
    ML_RUNTIME_DESCRIPTION="ML Runtime to accompany Cohere Toolkit" \
    ML_RUNTIME_EDITOR="Cohere Toolkit" \
    ML_RUNTIME_KERNEL="Python 3.11" \
    ML_RUNTIME_METADATA_VERSION="1" \
    ML_RUNTIME_SHORT_VERSION="2024.07" \
    PG_APP_HOME=/etc/docker-app \
    PYTHON_VERSION=3.11.8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=utf-8 \
    LANG=C.UTF-8 \
    PYTHONPATH=/workspace/src/ \
    VIRTUAL_ENV=/workspace/.venv \
    PATH="$VIRTUAL_ENV/bin:$PATH" \
    POETRY_VIRTUALENVS_IN_PROJECT=true

# Install Python and other necessary packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    krb5-user python3.11 python3-pip python-is-python3 ssh xz-utils && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Configure pip to install packages under /usr/local
RUN pip3 config set install.user false

# Install the Jupyter kernel gateway
RUN pip3 install "jupyter-kernel-gateway==2.5.2"

# Associate uid and gid 8536 with username cdsw
RUN addgroup --gid 8536 cdsw && \
    adduser --disabled-password --gecos "CDSW User" --uid 8536 --gid 8536 cdsw

# Set up Python symlink to /usr/local/bin/python3
RUN ln -s $(which python) /usr/local/bin/python3

# Configure pip to install packages to /home/cdsw
RUN echo -e '[install]\nuser = true' > /etc/pip.conf

# # Create a new layer from Python
# FROM python:3.11

# # Upgrade packages in the base image
# RUN apt-get update && apt-get upgrade -y && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy entrypoint script
COPY docker_scripts/gcp-entrypoint.sh /sbin/gcp-entrypoint.sh
RUN chmod 755 /sbin/gcp-entrypoint.sh && \
    curl -sL https://deb.nodesource.com/setup_18.x | bash - && \
    apt-get update && apt-get install --no-install-recommends -y nginx nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    npm install -g pnpm pm2

# Copy nginx config
COPY docker_scripts/nginx.conf /etc/nginx/nginx.conf

WORKDIR /workspace

# Copy dependency files
COPY pyproject.toml poetry.lock ./

# Check Poetry version and Python version
RUN python3 --version && \
    pip3 --version && \
    pip3 install --no-cache-dir poetry==1.6.1 && \
    poetry --version

# Install dependencies
RUN poetry config installer.max-workers 10 && \
    poetry install && \
    poetry cache clear pypi --all --no-interaction

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
RUN npm install && npm run next:build

# Copy Terrarium files
WORKDIR /usr/src/app
COPY --from=terrarium /usr/src/app/package*.json ./
RUN npm install -g ts-node && \
    npm install && \
    npm prune --production
COPY --from=terrarium /usr/src/app/. .
ENV ENV_RUN_AS "docker"

# Expose ports
EXPOSE 4000/tcp
EXPOSE 8000/tcp
EXPOSE 8090/tcp

ENV CDSW_APP_PORT=4000

# Set entrypoint
CMD ["/sbin/gcp-entrypoint.sh"]

# Relax permissions to facilitate installation of Cloudera client files at startup
RUN for i in /bin /opt /usr /usr/lib/hadoop /usr/share/java /workspace; do \
        mkdir -p ${i}; \
        chown cdsw ${i}; \
        chmod +rw ${i}; \
        find ${i} -type d -exec chown cdsw {} \; -exec chmod +rw {} \; \
    done && \
    for i in /etc /usr/lib/hadoop /etc/alternatives /runtime-addons; do \
        mkdir -p ${i}; \
        chmod 777 ${i}; \
    done



# Set labels
LABEL com.cloudera.ml.runtime.edition=$ML_RUNTIME_EDITION \
      com.cloudera.ml.runtime.full-version=$ML_RUNTIME_FULL_VERSION \
      com.cloudera.ml.runtime.short-version=$ML_RUNTIME_SHORT_VERSION \
      com.cloudera.ml.runtime.maintenance-version=$ML_RUNTIME_MAINTENANCE_VERSION \
      com.cloudera.ml.runtime.description=$ML_RUNTIME_DESCRIPTION \
      com.cloudera.ml.runtime.editor=$ML_RUNTIME_EDITOR \
      com.cloudera.ml.runtime.kernel=$ML_RUNTIME_KERNEL \
      com.cloudera.ml.runtime.runtime-metadata-version=$ML_RUNTIME_METADATA_VERSION \
      com.cloudera.ml.runtime.short-version=$ML_RUNTIME_SHORT_VERSION \
      authors="Cloudera"
