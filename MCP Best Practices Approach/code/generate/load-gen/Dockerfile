# Build + run the Ballerina traffic generator. The base image carries the
# matching Java 21 runtime, so the self-contained executable jar runs directly.
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
COPY --from=build /home/ballerina/app/patterns ./patterns
# 9797 = prometheus metrics (load-gen has no HTTP API; it's a driver)
EXPOSE 9797
CMD ["bal", "run", "app.jar"]
