# Para build local: docker build -f Dockerfile.base -t github-runner-base:latest .
# Para CI: se usa la imagen publicada en GHCR (pasar --build-arg BASE_IMAGE=ghcr.io/...)
ARG BASE_IMAGE=github-runner-base:latest
FROM ${BASE_IMAGE}

# Switch to root for installation steps
USER root

LABEL maintainer="Daniel Morales"

ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
ENV YARN_CACHE_FOLDER=/usr/local/share/.cache/yarn
RUN mkdir -p /opt/hostedtoolcache /usr/local/share/.cache/yarn \
  && chown -R runner /usr/local/share/.cache

ARG GH_RUNNER_VERSION="2.336.0"
ARG TARGETPLATFORM

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /actions-runner

COPY scripts/install_actions.sh /actions-runner/
RUN chmod +x /actions-runner/install_actions.sh \
  && /actions-runner/install_actions.sh ${GH_RUNNER_VERSION} ${TARGETPLATFORM} \
  && rm /actions-runner/install_actions.sh \
  && chown -R runner /_work /actions-runner /opt/hostedtoolcache

COPY scripts/token.sh scripts/entrypoint.sh scripts/app_token.sh /
RUN chmod +x /token.sh /entrypoint.sh /app_token.sh

USER runner

ENTRYPOINT ["/entrypoint.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
