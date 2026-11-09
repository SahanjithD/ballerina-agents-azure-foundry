# Build the jar first with `bal build` (from hr_agent/), then:
#   docker buildx build --platform linux/amd64 -t <acr>.azurecr.io/bal-demo-agent:v1 .
# Ballerina 2201.14 compiles to Java 25 bytecode.
FROM eclipse-temurin:25-jre

WORKDIR /app
COPY target/bin/hr_agent.jar /app/hr_agent.jar

EXPOSE 8088
ENTRYPOINT ["java", "-jar", "/app/hr_agent.jar"]
