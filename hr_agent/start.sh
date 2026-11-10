#!/bin/sh
# Container entrypoint. Foundry runs one container per session, so the OpenTelemetry Collector runs here
# as a second process. It only starts when an Application Insights connection string is available.
if [ -n "$APPLICATIONINSIGHTS_CONNECTION_STRING" ]; then
    /app/otelcol --config=/app/collector.yaml &
else
    echo "APPLICATIONINSIGHTS_CONNECTION_STRING not set; traces will not be exported" >&2
fi
exec java -jar /app/hr_agent.jar
