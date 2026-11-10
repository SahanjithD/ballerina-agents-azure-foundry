# Build the jar first with `bal build` (from hr_agent/), then:
#   docker buildx build --platform linux/amd64 -t <acr>.azurecr.io/bal-demo-agent:v1 .

# Slim OpenTelemetry Collector built for the target platform (see otel/builder-config.yaml).
FROM --platform=$BUILDPLATFORM golang:1.26.2 AS otelcol
ARG TARGETOS TARGETARCH
RUN go install go.opentelemetry.io/collector/cmd/builder@v0.164.0
COPY otel/builder-config.yaml /src/builder-config.yaml
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH builder --config=/src/builder-config.yaml

# Ballerina 2201.14 compiles to Java 25 bytecode.
FROM eclipse-temurin:25-jre

WORKDIR /app
COPY --from=otelcol /build/otelcol /app/otelcol
COPY otel/collector.yaml /app/collector.yaml
COPY otel/Config.toml /app/Config.toml
COPY start.sh /app/start.sh
COPY target/bin/hr_agent.jar /app/hr_agent.jar

ENV BAL_CONFIG_FILES=/app/Config.toml
EXPOSE 8088
ENTRYPOINT ["/app/start.sh"]
