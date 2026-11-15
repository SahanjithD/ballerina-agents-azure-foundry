# The Ballerina JAR is built on the host first (`bal build` in hr_agent/, as deploy.sh does), so no Ballerina
# distribution or Central access is needed inside the image. This also lets the build use packages from the
# local Ballerina repository (ballerinax/ai.azure 1.6.0). Then, from hr_agent/:
#   docker build --platform linux/amd64 -t hr-agent:<unique-tag> .

# BuildKit sets these automatically. The defaults are used only by a builder that doesn't (the classic
# builder), which then builds natively for linux/amd64.
ARG BUILDPLATFORM=linux/amd64
ARG TARGETOS=linux
ARG TARGETARCH=amd64

# 1. Slim OpenTelemetry Collector built for the target platform (see otel/builder-config.yaml).
FROM --platform=$BUILDPLATFORM golang:1.26.2 AS otelcol
ARG TARGETOS TARGETARCH
RUN go install go.opentelemetry.io/collector/cmd/builder@v0.164.0
COPY otel/builder-config.yaml /src/builder-config.yaml
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH builder --config=/src/builder-config.yaml

# 2. Runtime. Ballerina 2201.14 compiles to Java 25 bytecode.
FROM eclipse-temurin:25-jre

WORKDIR /app
COPY --from=otelcol /build/otelcol /app/otelcol
COPY otel/collector.yaml /app/collector.yaml
COPY otel/tracing.toml /app/tracing.toml
COPY start.sh /app/start.sh
COPY target/bin/hr_agent.jar /app/hr_agent.jar

ENV BAL_CONFIG_FILES=/app/tracing.toml
# Hosted agent contract: plain HTTP on 8088 (GET /readiness, POST /invocations).
EXPOSE 8088
ENTRYPOINT ["/app/start.sh"]
