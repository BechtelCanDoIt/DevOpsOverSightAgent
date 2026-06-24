FROM ballerina/ballerina:2201.13.3 AS build
USER root
WORKDIR /home/ballerina/app
COPY generate/agent/ .
RUN bal build

FROM ballerina/ballerina:2201.13.3
WORKDIR /home/ballerina
COPY --from=build /home/ballerina/app/target/bin/devops_oversight_agent.jar app.jar
COPY --from=build /home/ballerina/app/Config.toml Config.toml
EXPOSE 8080
CMD ["bal", "run", "app.jar"]
