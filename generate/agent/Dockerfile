FROM ballerina/ballerina:2201.13.3 AS build
USER root
ENV HOME=/home/ballerina
WORKDIR /home/ballerina/app
COPY generate/agent/ .
RUN JAVA_OPTS="-Duser.home=/home/ballerina" bal build

FROM ballerina/ballerina:2201.13.3
WORKDIR /home/ballerina
COPY --from=build /home/ballerina/app/target/bin/devops_oversight_agent.jar app.jar
COPY --from=build /home/ballerina/app/Config.toml Config.toml
EXPOSE 8000
CMD ["bal", "run", "app.jar"]
