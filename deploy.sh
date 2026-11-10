#!/usr/bin/env bash
# Builds the HR agent image, pushes it to ACR and creates a new Foundry hosted-agent version.
# Usage: ./deploy.sh <tag>      e.g. ./deploy.sh v1
# Reads AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_KEY and MODEL_DEPLOYMENT_NAME from .env; never prints them.
set -euo pipefail

TAG="${1:?usage: ./deploy.sh <tag>, e.g. v1 (unique per deploy, never latest)}"
[[ "$TAG" == "latest" ]] && { echo "Refusing to use the 'latest' tag" >&2; exit 1; }

RG=rg-foundry-dasuns
FOUNDRY=foundry-dasuns-demo
PROJECT=ballerina-demo
ACR=acrdasunsdemo
AGENT=bal-demo-agent

IMAGE="${ACR}.azurecr.io/${AGENT}:${TAG}"
BASE_URL="https://${FOUNDRY}.services.ai.azure.com/api/projects/${PROJECT}"
API_VERSION=v1
ROOT="$(cd "$(dirname "$0")" && pwd)"
AGENT_JSON="${ROOT}/agent.json"

set -a; source "${ROOT}/.env"; set +a
for var in AZURE_OPENAI_ENDPOINT AZURE_OPENAI_KEY MODEL_DEPLOYMENT_NAME; do
    [[ -n "${!var:-}" ]] || { echo "${var} is not set in .env" >&2; exit 1; }
done
[[ "${AZURE_OPENAI_ENDPOINT%/}" == */openai/v1 ]] \
    || { echo "AZURE_OPENAI_ENDPOINT must end with /openai/v1" >&2; exit 1; }

echo "==> Building jar"
(cd "${ROOT}/hr_agent" && bal build --locking-mode=soft)

echo "==> Logging in to ${ACR}"
az acr login -n "$ACR" -g "$RG"

if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
    echo "${IMAGE} already exists; pick a new tag" >&2
    exit 1
fi

echo "==> Building and pushing ${IMAGE}"
docker buildx build --platform linux/amd64 -t "$IMAGE" --push "${ROOT}/hr_agent"

TOKEN="$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)"

# Creates the agent on the first deploy, otherwise adds a version to it.
status=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/agents/${AGENT}?api-version=${API_VERSION}")
if [[ "$status" == "404" ]]; then
    echo "==> Creating agent ${AGENT}"
    url="${BASE_URL}/agents?api-version=${API_VERSION}"
    name="$AGENT"
else
    echo "==> Creating new version of ${AGENT}"
    url="${BASE_URL}/agents/${AGENT}/versions?api-version=${API_VERSION}"
    name=""
fi

# The definition carries the model key, so it goes in a gitignored, owner-only file and is posted
# from there rather than on the command line.
umask 077
jq -n --arg name "$name" --arg image "$IMAGE" \
    --arg endpoint "$AZURE_OPENAI_ENDPOINT" \
    --arg key "$AZURE_OPENAI_KEY" \
    --arg deployment "$MODEL_DEPLOYMENT_NAME" \
    '(if $name == "" then {} else {name: $name} end) + {
        definition: {
            kind: "hosted",
            container_configuration: {image: $image},
            cpu: "1",
            memory: "2Gi",
            protocol_versions: [{protocol: "invocations", version: "2.0.0"}],
            environment_variables: {
                AZURE_OPENAI_ENDPOINT: $endpoint,
                AZURE_OPENAI_KEY: $key,
                MODEL_DEPLOYMENT_NAME: $deployment
            }
        }
    }' > "$AGENT_JSON"

response="$(curl -s -w '\n%{http_code}' -X POST "$url" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data-binary "@${AGENT_JSON}")"
code="${response##*$'\n'}"
response="${response%$'\n'*}"
if [[ "$code" != 2* ]]; then
    echo "Create failed (HTTP ${code}):" >&2
    echo "$response" | jq '.error // .' >&2 || echo "$response" >&2
    exit 1
fi
VERSION="$(echo "$response" | jq -r '.version // .versions.latest.version // empty')"
[[ -n "$VERSION" ]] || { echo "Could not read the new version from the response" >&2; exit 1; }

echo "==> Waiting for ${AGENT} version ${VERSION} to become active"
for _ in $(seq 1 60); do
    version_json="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
        "${BASE_URL}/agents/${AGENT}/versions/${VERSION}?api-version=${API_VERSION}")"
    state="$(echo "$version_json" | jq -r '.status // "unknown"')"
    echo "    status: ${state}"
    case "$state" in
        active) break ;;
        failed) echo "$version_json" | jq '.error' >&2; exit 1 ;;
    esac
    sleep 10
done
[[ "$state" == "active" ]] || { echo "Timed out waiting for the version to become active" >&2; exit 1; }

cat <<EOF

Deployed ${IMAGE} as ${AGENT} version ${VERSION}.
Try it (Foundry issues session IDs: omit agent_session_id on the first call, then reuse the
x-agent-session-id response header on later calls to keep the conversation):
  TOKEN=\$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
  curl -s -D - -X POST "${BASE_URL}/agents/${AGENT}/endpoint/protocols/invocations?api-version=${API_VERSION}" \\
    -H "Authorization: Bearer \$TOKEN" -H "Content-Type: application/json" \\
    -d '{"message":"How much leave do I have left?","employeeId":"E1001"}'
  # follow-ups: add &agent_session_id=<x-agent-session-id from the first response> to the URL
EOF
