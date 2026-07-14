# Builds a runnable image from a LOCALLY-EXTRACTED WSO2 product distribution.
#
# Why build our own instead of pulling registry.wso2.com / docker.wso2.com:
# those images are amd64-only, so they need QEMU emulation on Apple Silicon
# (which errors with "exec format error" here). WSO2 products are pure Java,
# so layering the extracted distribution onto a MULTI-ARCH Temurin base makes
# the image run NATIVELY on arm64 or amd64 — no emulation, no registry access.
#
# The build context MUST be the extracted product directory. Example:
#   docker build -f compose/wso2/Dockerfile \
#     --build-arg PRODUCT_DIR=wso2mi-4.2.0 \
#     --build-arg START_CMD=bin/micro-integrator.sh \
#     -t devops-poc/wso2mi:4.2.0  ~/dev/wso2/mi/wso2mi-4.2.0
#
# scripts/build-wso2-images.sh wraps this for all three products.

# 11-jdk-jammy is multi-arch (linux/amd64 + linux/arm64); WSO2 4.2.0/6.1.0
# all require Java 11. Docker selects the arch matching the host automatically.
FROM eclipse-temurin:11-jdk-jammy

ARG PRODUCT_DIR
ARG START_CMD
ENV WSO2_SERVER_HOME=/home/wso2carbon/${PRODUCT_DIR}
ENV START_CMD=${START_CMD}

# curl: for container HEALTHCHECK / debugging. wso2carbon (uid 10001): WSO2's
# conventional non-root runtime user, matching their official images.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system -g 10001 wso2carbon \
    && useradd --system -g wso2carbon -u 10001 -m -d /home/wso2carbon wso2carbon

COPY --chown=wso2carbon:wso2carbon . ${WSO2_SERVER_HOME}/
RUN chmod +x ${WSO2_SERVER_HOME}/bin/*.sh

USER wso2carbon
WORKDIR ${WSO2_SERVER_HOME}

# START_CMD is relative to WSO2_SERVER_HOME (e.g. bin/micro-integrator.sh); the
# WSO2 launchers run in the foreground, which is exactly what a container wants.
CMD ["sh", "-c", "exec ./${START_CMD}"]
