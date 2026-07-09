# IMPORTANT: the base image declares `VOLUME /home/ballerina`. Doing build work or
# placing the runnable jar UNDER that path makes Docker's volume semantics shadow/
# discard the files — every rebuild then silently ships stale code. So we build in
# /build and run from /app, both OUTSIDE the volume path. HOME stays /home/ballerina
# only so `bal` finds the base image's pre-cached package repository (read-only use).
FROM ballerina/ballerina:2201.13.3 AS build
USER root
ENV HOME=/home/ballerina
WORKDIR /build
COPY code/agent/ .
RUN JAVA_OPTS="-Duser.home=/home/ballerina" bal build

FROM ballerina/ballerina:2201.13.3
USER root
WORKDIR /app
COPY --from=build /build/target/bin/devops_oversight_agent.jar app.jar
COPY --from=build /build/Config.toml Config.toml
RUN chown -R ballerina:troupe /app
USER ballerina
EXPOSE 8000
CMD ["bal", "run", "app.jar"]
