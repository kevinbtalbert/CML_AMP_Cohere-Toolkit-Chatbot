# This Dockerfile is intended for One-Click deployment to Google Cloud Run
# ------------------------------------------------------------------------
  FROM --platform=linux/amd64 ubuntu:22.04
  # FROM docker.repository.cloudera.com/cloudera/cdsw/ml-runtime-jupyterlab-python3.11-cuda:2024.05.1-b8
  USER root
  FROM --platform=linux/amd64 ghcr.io/cohere-ai/terrarium:latest AS terrarium
  
  FROM --platform=linux/amd64 python:3.11
  LABEL authors="Cloudera"
  ENV PG_APP_HOME=/etc/docker-app
  ENV PYTHON_VERSION=3.11.8
  ENV PYTHONDONTWRITEBYTECODE=1
  ENV PYTHONUNBUFFERED=1
  ENV PYTHONIOENCODING=utf-8
  ENV LANG=C.UTF-8
  ENV PYTHONPATH=/workspace/src/
  COPY docker_scripts/gcp-entrypoint.sh /sbin/gcp-entrypoint.sh
  
  RUN chmod 755 /sbin/gcp-entrypoint.sh \
      && curl -sL https://deb.nodesource.com/setup_18.x | bash - \
      && apt-get update \
      && apt-get install --no-install-recommends -y python-is-python3 nginx nodejs ssh xz-utils krb5-user \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
      && npm install -g pnpm \
      && npm install -g pm2
  
  # Copy nginx config
  COPY docker_scripts/nginx.conf /etc/nginx/nginx.conf
  
  WORKDIR /workspace
  
  # Copy dependency files to avoid cache invalidations
  COPY pyproject.toml poetry.lock ./
  
  # Install dependencies
  RUN pip3 install --no-cache-dir poetry==1.6.1 \
      && poetry config installer.max-workers 10 \
      && poetry install --no-dev --no-root \
      && (poetry cache clear --all --no-interaction PyPI || true) \
      && (poetry cache clear --all --no-interaction _default_cache || true)
  
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
  
  # Terrarium
  WORKDIR /usr/src/app
  COPY --from=terrarium /usr/src/app/package*.json ./
  RUN npm install -g ts-node \
      && npm install \
      && npm prune --production
  COPY --from=terrarium /usr/src/app/. .
  ENV ENV_RUN_AS="docker"
  
  # Ports to expose
  EXPOSE 4000/tcp
  EXPOSE 8000/tcp
  EXPOSE 8090/tcp
  ENV CDSW_APP_PORT=4000
  
  CMD ["/sbin/gcp-entrypoint.sh"]
  
  # Configure pip to install packages under /usr/local
  # when building the Runtime image
  # RUN pip3 config set global.user false
  
  # Install the Jupyter kernel gateway.
  # The IPython kernel is automatically installed 
  # under the name python3,
  # so below we set the kernel name to python3.
  RUN pip3 install "jupyter-kernel-gateway==2.5.2"
  
  # Associate uid and gid 8536 with username cdsw
  RUN addgroup --gid 8536 cdsw \
      && adduser --disabled-password --gecos "CDSW User" --uid 8536 --gid 8536 cdsw
  
  # Install any additional packages.
  # apt-get install ...
  # pip install ...
  
  # Configure pip to install packages to /home/cdsw
  # once the Runtime image is loaded into CML
  # do not install Python packages in the Dockerfile after this line
  RUN /bin/bash -c "echo -e '[install]\nuser = true'" > /etc/pip.conf
  
  # Relax permissions to facilitate installation of Cloudera
  # client files at startup
  RUN chown cdsw / \
      && for i in /bin /var /etc /sbin /home /runtime-addons /opt /usr /tmp /usr/share/java /workspace; do \
          mkdir -p ${i}; \
          chown cdsw ${i}; \
          chmod +rwx ${i}; \
          for subfolder in `find ${i} -type d`; do \
              chown cdsw ${subfolder}; \
              chmod +rwx ${subfolder}; \
          done; \
      done
  
  RUN for i in /etc /etc/alternatives; do \
      mkdir -p ${i}; \
      chmod 777 ${i}; \
      done
  
  USER cdsw
  
  # Set environment variables
  ENV ML_RUNTIME_EDITION="ML Runtime for Cohere Toolkit" \
      ML_RUNTIME_SHORT_VERSION="1" \
      ML_RUNTIME_MAINTENANCE_VERSION="17" \
      ML_RUNTIME_FULL_VERSION="2024.07.17" \
      ML_RUNTIME_DESCRIPTION="ML Runtime to accompany Cohere Toolkit" \
      ML_RUNTIME_EDITOR="PBJ Workbench" \
      ML_RUNTIME_KERNEL="Python 3.11" \
      ML_RUNTIME_JUPYTER_KERNEL_GATEWAY_CMD="/usr/local/bin/jupyter kernelgateway" \
      ML_RUNTIME_JUPYTER_KERNEL_NAME="python3" \
      ML_RUNTIME_METADATA_VERSION="2" \
      ML_RUNTIME_SHORT_VERSION="2024.07"
  
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
  