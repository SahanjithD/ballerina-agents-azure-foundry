# Self-contained build: the Ballerina JAR is compiled inside Docker, so `docker build .` (from hr_agent/)
# works on its own, locally with buildx or remotely with ACR Tasks (azd container deploy):
#   docker buildx build --platform linux/amd64 -t <acr>.azurecr.io/bal-demo-agent:v1 .

# BuildKit sets these automatically. The defaults are used only by a builder that doesn't (the classic
# builder), which then builds natively for linux/amd64.
ARG BUILDPLATFORM=linux/amd64
ARG TARGETOS=linux
ARG TARGETARCH=amd64

# 1. Ballerina JAR. Same distribution as Ballerina.toml. The JAR is platform-independent, so this stage runs
# natively on the build machine. `bal build` only compiles (it doesn't run tests), as in deploy.sh; the
# image runs as `ballerina`, so root is needed to write target/ in this throwaway stage.
FROM --platform=$BUILDPLATFORM ballerina/ballerina:2201.14.0 AS jar
USER root
WORKDIR /src
COPY Ballerina.toml Dependencies.toml ./
COPY *.bal ./
RUN bal build --locking-mode=soft

# 2. Slim OpenTelemetry Collector built for the target platform (see otel/builder-config.yaml).
FROM --platform=$BUILDPLATFORM golang:1.26.2 AS otelcol
ARG TARGETOS TARGETARCH
RUN go install go.opentelemetry.io/collector/cmd/builder@v0.164.0
COPY otel/builder-config.yaml /src/builder-config.yaml
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH builder --config=/src/builder-config.yaml

# 3. Runtime. Ballerina 2201.14 compiles to Java 25 bytecode.
FROM eclipse-temurin:25-jre

WORKDIR /app
COPY --from=otelcol /build/otelcol /app/otelcol
COPY otel/collector.yaml /app/collector.yaml
COPY otel/tracing.toml /app/tracing.toml
COPY start.sh /app/start.sh
COPY --from=jar /src/target/bin/hr_agent.jar /app/hr_agent.jar

ENV BAL_CONFIG_FILES=/app/tracing.toml
EXPOSE 8088
ENTRYPOINT ["/app/start.sh"]
