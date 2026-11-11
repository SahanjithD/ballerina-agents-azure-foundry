# Ballerina HR agent on Microsoft Foundry

A Ballerina `ai:Agent` (an HR assistant with six tools over mock data) packaged as a Microsoft Foundry
**hosted agent** using the Invocations protocol. Ballerina has no official hosted-agent SDK, so the
container implements the host contract itself, following Microsoft's `azure-ai-agentserver` host.

## Layout

| Path | What it is |
| --- | --- |
| `hr_agent/main.bal` | HTTP service on port 8088: `/readiness`, `/invocations`, the OpenAPI route, session handling |
| `hr_agent/host.bal` | Host behaviour shared by all routes: platform headers, request IDs, error sources |
| `hr_agent/agent.bal` | Model provider and the `ai:Agent` |
| `hr_agent/tools.bal`, `data.bal`, `types.bal` | HR tools, mock data and types |
| `hr_agent/openapi.bal` | OpenAPI document for the invocation JSON |
| `hr_agent/otel/`, `hr_agent/start.sh` | Tracing: Ballerina OTLP exporter → in-container OpenTelemetry Collector → Application Insights |
| `hr_agent/tests/` | Unit and HTTP tests |
| `deploy.sh` | Builds and pushes the image and creates a new hosted-agent version |

## Run locally

Copy `.env.example` to `.env` and fill it in, then:

```sh
cd hr_agent && bal build && cd ..
set -a && source .env && set +a && java -jar hr_agent/target/bin/hr_agent.jar
curl -X POST localhost:8088/invocations -H 'Content-Type: application/json' \
  -d '{"message":"How much leave do I have left?","employeeId":"E1001"}'
```

Tests: the module reads its model settings when it starts, so the tests need them set. Placeholder values
are enough because no test calls the model. Port 8088 must be free.

```sh
cd hr_agent
AZURE_OPENAI_ENDPOINT=https://unused.invalid/openai/v1 AZURE_OPENAI_KEY=unused MODEL_DEPLOYMENT_NAME=unused bal test
```

## Deploy

```sh
./deploy.sh v6    # a new, unique tag each time; never "latest"
```

## API

### `POST /invocations`

The body can be any of the following:

- `{"message": "...", "employeeId": "E1001"}`: `employeeId` is optional and tells the agent who is asking
- `{"input": "..."}`: what the Foundry playground sends
- a JSON string, or a `text/plain` body

A successful call returns `200` with `{"response": "...", "sessionId": "..."}`. Errors return
`{"message": "..."}`, with `400` for a bad request and `500` when the model or the service fails.

### `GET /readiness`

Returns `200` once the service is up. Foundry waits for this before sending traffic.

### `GET /invocations/docs/openapi.json`

An OpenAPI 3.0 description of the request and response bodies, the `agent_session_id` parameter, and the
error shape.

## Sessions

Foundry runs each session in its own sandbox and routes calls by the `agent_session_id` query parameter.
To continue a conversation, send the same `agent_session_id` on every call. Foundry issues the IDs: make the
first call without one, then reuse the `x-agent-session-id` response header.

Inside the container, the conversation memory is keyed like this:

1. `FOUNDRY_AGENT_SESSION_ID`, set by Foundry in the sandbox. If `agent_session_id` is also sent and
   differs from it, the call is **rejected with 400** (`x-platform-error-source: user`), as Microsoft's Agent
   Framework host does.
2. The `agent_session_id` query parameter, when running outside Foundry.
3. The body's `sessionId`, for local testing only.
4. `default`.

## Response headers

| Header | When | Value |
| --- | --- | --- |
| `x-platform-server` | every response | `bal-foundry-host/<version> (ballerina/<distribution>)`, from `Ballerina.toml` |
| `x-request-id` | every response | the caller's `x-request-id` if sent, otherwise the trace ID, otherwise a new UUID |
| `x-agent-session-id` | successful `/invocations` | the session ID used for the conversation memory |
| `x-platform-error-source` | every 4xx and 5xx | `user` (bad request, session mismatch, unknown route), `upstream` (the model call failed: an `ai:LlmError` in the error chain), `platform` (any other failure in this service) |

`x-platform-server` uses constants in `host.bal`. A test fails if they drift from the `version` and
`distribution` in `Ballerina.toml`.
