FROM ballerina/ballerina:2201.13.3 AS build
WORKDIR /home/ballerina/app
COPY --chown=ballerina:ballerina . .
RUN bal build

FROM ballerina/ballerina:2201.13.3
WORKDIR /app
COPY --from=build /home/ballerina/app/target/bin/mcp_server.jar app.jar
COPY --from=build /home/ballerina/app/Config.toml Config.toml
EXPOSE 8290
CMD ["bal", "run", "app.jar"]
