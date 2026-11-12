#!/usr/bin/env bash
# Builds the HR agent image, pushes it to ACR and creates a new Foundry hosted-agent version.
# Usage: ./deploy.sh <tag>      e.g. ./deploy.sh v1
# Reads AZURE_OPENAI_ENDPOINT and MODEL_DEPLOYMENT_NAME from .env. AZURE_OPENAI_KEY stays local: in Foundry the
# agent calls the model with its own Entra identity, which needs Foundry User on the Foundry resource.
#
# In short, this script does 6 things:
#   1. Check the inputs (tag and .env values)
#   2. Compile the Ballerina code into a .jar file
#   3. Put the .jar in a Docker image and upload it to our Azure Container Registry (ACR)
#   4. Tell Foundry "run this image as agent bal-demo-agent" (creates the agent, or a new version of it)
#   5. Wait until Foundry says the new version is running
#   6. Print a curl command you can use to talk to the agent

# Stop at the first error (-e), treat unset variables as errors (-u), and fail if any command in a pipe fails.
set -euo pipefail

# ---------------------------------------------------------------------------------------------------------
# Step 1: Check the inputs
# ---------------------------------------------------------------------------------------------------------

# The first argument is the image tag (v1, v2, ...). Every deploy needs a new one so Foundry
# always pulls the exact image we just built. "latest" is not allowed.
TAG="${1:?usage: ./deploy.sh <tag>, e.g. v1 (unique per deploy, never latest)}"
[[ "$TAG" == "latest" ]] && { echo "Refusing to use the 'latest' tag" >&2; exit 1; }

# Names of our Azure resources.
RG=rg-foundry-dasuns          # resource group: everything lives here
FOUNDRY=foundry-dasuns-demo   # Foundry resource (hosts the model and the agent)
PROJECT=ballerina-demo        # Foundry project inside that resource
ACR=acrdasunsdemo             # Azure Container Registry: where the Docker image is stored
AGENT=bal-demo-agent          # name of the hosted agent in Foundry

# Full image name, e.g. acrdasunsdemo.azurecr.io/bal-demo-agent:v6
IMAGE="${ACR}.azurecr.io/${AGENT}:${TAG}"
# Base URL of the Foundry project's REST API. All agent calls below start with this.
BASE_URL="https://${FOUNDRY}.services.ai.azure.com/api/projects/${PROJECT}"
API_VERSION=v1
# Folder this script is in (the repo root), so the script works from any directory.
ROOT="$(cd "$(dirname "$0")" && pwd)"
# File where we write the agent definition before sending it to Foundry (gitignored).
AGENT_JSON="${ROOT}/agent.json"

# Load .env into environment variables (set -a exports everything it loads).
set -a; source "${ROOT}/.env"; set +a
# Make sure the two values the agent needs in Foundry are present.
for var in AZURE_OPENAI_ENDPOINT MODEL_DEPLOYMENT_NAME; do
    [[ -n "${!var:-}" ]] || { echo "${var} is not set in .env" >&2; exit 1; }
done
# The agent code expects the new-style endpoint, e.g. https://<name>.openai.azure.com/openai/v1
[[ "${AZURE_OPENAI_ENDPOINT%/}" == */openai/v1 ]] \
    || { echo "AZURE_OPENAI_ENDPOINT must end with /openai/v1" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------------
# Step 2: Compile the Ballerina code -> hr_agent/target/bin/hr_agent.jar
# ---------------------------------------------------------------------------------------------------------
echo "==> Building jar"
(cd "${ROOT}/hr_agent" && bal build --locking-mode=soft)

# ---------------------------------------------------------------------------------------------------------
# Step 3: Build the Docker image and upload it to ACR
# ---------------------------------------------------------------------------------------------------------

# Let Docker push to our registry using your az login.
echo "==> Logging in to ${ACR}"
az acr login -n "$ACR" -g "$RG"

# If this tag is already in the registry, stop. Overwriting it would make versions confusing.
if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
    echo "${IMAGE} already exists; pick a new tag" >&2
    exit 1
fi

# Build the image from hr_agent/Dockerfile (it copies in the .jar from step 2) and push it.
# Foundry runs on Intel/AMD Linux, so we build for linux/amd64 even on an Apple Silicon Mac.
echo "==> Building and pushing ${IMAGE}"
docker buildx build --platform linux/amd64 -t "$IMAGE" --push "${ROOT}/hr_agent"

# ---------------------------------------------------------------------------------------------------------
# Step 4: Tell Foundry to run this image as the agent
# ---------------------------------------------------------------------------------------------------------

# Get a login token for the Foundry API, using your az login. Sent as "Authorization: Bearer ..." below.
TOKEN="$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)"

# Does the agent already exist? Ask Foundry for it and look only at the HTTP status code.
#   404 -> first deploy: create the agent (POST /agents, with a "name" in the body)
#   else -> it exists: add a new version (POST /agents/<name>/versions, no name needed)
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

# Write the agent definition (JSON) to agent.json. It says:
#   kind: hosted               -> Foundry runs our own container
#   image                      -> the image we just pushed
#   cpu / memory               -> size of each session's container
#   protocol: invocations      -> Foundry forwards calls to our POST /invocations on port 8088
#   idle_timeout_seconds: 300  -> a session's container shuts down after 5 min with no calls
#   environment_variables      -> values the Ballerina code reads at startup (no API key; see top)
# umask 077 makes the file readable only by you.
umask 077
jq -n --arg name "$name" --arg image "$IMAGE" \
    --arg endpoint "$AZURE_OPENAI_ENDPOINT" \
    --arg deployment "$MODEL_DEPLOYMENT_NAME" \
    '(if $name == "" then {} else {name: $name} end) + {
        definition: {
            kind: "hosted",
            container_configuration: {image: $image},
            cpu: "1",
            memory: "2Gi",
            protocol_versions: [{protocol: "invocations", version: "2.0.0"}],
            session_configuration: {idle_timeout_seconds: 300},
            environment_variables: {
                AZURE_OPENAI_ENDPOINT: $endpoint,
                MODEL_DEPLOYMENT_NAME: $deployment
            }
        }
    }' > "$AGENT_JSON"

# Send the definition to Foundry. curl prints the response body, then the HTTP code on the last line;
# the two lines after it split those apart.
response="$(curl -s -w '\n%{http_code}' -X POST "$url" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data-binary "@${AGENT_JSON}")"
code="${response##*$'\n'}"
response="${response%$'\n'*}"
# Anything other than 2xx means Foundry rejected it: show its error and stop.
if [[ "$code" != 2* ]]; then
    echo "Create failed (HTTP ${code}):" >&2
    echo "$response" | jq '.error // .' >&2 || echo "$response" >&2
    exit 1
fi
# Foundry numbers versions itself (1, 2, 3, ...). Read the new number from the response.
VERSION="$(echo "$response" | jq -r '.version // .versions.latest.version // empty')"
[[ -n "$VERSION" ]] || { echo "Could not read the new version from the response" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------------
# Step 5: Wait until the new version is running
# ---------------------------------------------------------------------------------------------------------
# Foundry pulls the image and starts it in the background. Check the status every 10 s, for up to
# 10 minutes (60 tries): "active" means ready, "failed" means it didn't start (we print why).
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

# ---------------------------------------------------------------------------------------------------------
# Step 6: Done. Print how to call the agent.
# ---------------------------------------------------------------------------------------------------------
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
