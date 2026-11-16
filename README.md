# Ballerina HR agent on Microsoft Foundry

A Ballerina `ai:Agent` (an HR assistant with six tools over mock data) packaged as a Microsoft Foundry
**hosted agent** using the Invocations protocol. The host contract (port, readiness, session and invocation IDs,
platform headers) comes from `azure:FoundryListener` in `ballerinax/ai.azure` 1.6.x, which follows Microsoft's
`azure-ai-agentserver` host. Until that version is on Ballerina Central, build ai.azure's `main` and publish it to
the local repository (`./gradlew build -x test -PpublishToLocalCentral=true`); `Ballerina.toml` expects 1.6.3.

## Layout

| Path | What it is |
| --- | --- |
| `hr_agent/main.bal` | `azure:FoundryInvocationService` on an `azure:FoundryListener`: `/readiness`, `/invocations`, request parsing, error sources |
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

For the full setup from scratch, see [docs/deploy-guide.md](docs/deploy-guide.md).

## Model authentication

| Where | How | Needs |
| --- | --- | --- |
| Foundry sandbox | The agent's own Entra identity (`bal-demo-agent-AgentIdentity`), with a token for `https://cognitiveservices.azure.com` from the sandbox's managed-identity endpoint | **Foundry User** on `foundry-dasuns-demo` for the agent identity (object ID = app ID `f57f194f-4573-4207-913f-72365879981b`) |
| Local runs | `AZURE_OPENAI_KEY` from `.env` | the key |

The mode is chosen at startup: if `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are set (as they are in a
Foundry sandbox), it's identity mode; otherwise key mode. The log shows `Model auth: agent identity` or
`Model auth: API key`, and never the secret.

- **Token request**: the same one azure-identity's `ManagedIdentityCredential` makes (App Service flow):
  `GET $IDENTITY_ENDPOINT?api-version=2019-08-01&resource=https://cognitiveservices.azure.com&client_id=$FOUNDRY_AGENT_INSTANCE_CLIENT_ID`
  with the header `X-IDENTITY-HEADER: $IDENTITY_HEADER`.
- **Caching**: tokens are cached and refreshed 5 minutes before they expire.
- **Why there's a local hop**: `ballerinax/ai.azure` 1.5.1 can only send an `api-key` header. In identity mode
  the provider calls a local hop on `127.0.0.1:8089`, which replaces that header with
  `Authorization: Bearer <token>` and forwards to `AZURE_OPENAI_ENDPOINT` (`hr_agent/identity.bal`). See
  `docs/upstream-proposal-ai-azure-entra-auth.md`.
- **No key in Foundry**: `deploy.sh` no longer sends `AZURE_OPENAI_KEY` to Foundry.
- **Token audiences**: `https://ai.azure.com` is for calling the Foundry agent endpoint (callers,
  `deploy.sh`); `https://cognitiveservices.azure.com` is for the agent calling the model.

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

Inside the container, the conversation memory is keyed by the listener's session ID (`ctx.sessionId`): the
`agent_session_id` query parameter, else `FOUNDRY_AGENT_SESSION_ID`, else a generated UUID. Locally, send
`?agent_session_id=<id>` to continue a conversation.

## Response headers

| Header | When | Value |
| --- | --- | --- |
| `x-platform-server` | every response | `ballerinax-ai.azure/<package version> (ballerina/<runtime version>)`, set by the listener |
| `x-request-id` | every response | set by the listener: the incoming `x-request-id` if sent, otherwise a trace or generated ID. In Foundry the gateway doesn't forward the caller's `x-request-id`. It adds its own (the trace ID) in front of the container's, so callers see `<gateway id>,<container id>` |
| `x-agent-session-id` | `/invocations` | the session ID used for the conversation memory |
| `x-agent-invocation-id` | `/invocations` | the invocation ID, set by the listener |
| `x-platform-error-source` | every 4xx and 5xx | `user` (bad request), `upstream` (the model call failed: an `ai:LlmError` in the error chain), `platform` (any other failure in this service) |
