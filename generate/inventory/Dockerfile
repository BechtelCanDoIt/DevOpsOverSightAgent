# Build + run a Ballerina service. The ballerina base image carries the matching
# Java 21 runtime, so the self-contained executable jar runs directly.
FROM ballerina/ballerina:2201.13.3 AS build
WORKDIR /home/ballerina/app
COPY --chown=ballerina:ballerina . .
RUN bal build

FROM ballerina/ballerina:2201.13.3
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
WORKDIR /app
COPY --from=build /home/ballerina/app/target/bin/*.jar app.jar
COPY --from=build /home/ballerina/app/Config.toml Config.toml
# 9090 = business + /health (host-mapped) · 9099 = /chaos (internal only) · 9797 = prometheus metrics
EXPOSE 9090 9099 9797
CMD ["bal", "run", "app.jar"]
