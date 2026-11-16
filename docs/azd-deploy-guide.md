# Deploy a Ballerina agent to Microsoft Foundry with azd

From an empty resource group to a running hosted agent. azd builds the image in Azure Container Registry (no
local Docker or Ballerina needed) and creates each agent version. Why this path: see
[azd-deploy-evaluation.md](azd-deploy-evaluation.md).

> **Shared subscription rules**
> - Run every `az` command with `-g $RG`. Never create or change anything outside your resource group.
> - Never run `azd up`, `azd provision`, `azd down` or a bare `azd deploy`. Only `azd deploy <agent>`.
> - No API keys anywhere: the agent calls the model with its own Entra identity.

```sh
# Your names (these are the demo's; change them for your setup)
RG=rg-foundry-dasuns
LOCATION=eastus
FOUNDRY=foundry-dasuns-demo        # Foundry resource; also its subdomain, so it must be globally unique
PROJECT=ballerina-demo
ACR=acrdasunsdemo                  # letters and digits only, globally unique
AGENT=bal-demo-agent
MODEL=gpt-5.5
TAG="RequestedBy=you@example.com"
```

## 0. Before you start

**From the maintainers:**
- A resource group (`$RG`) in the subscription. Keep everything in one region.
- **Owner** on the resource group, or someone who can create role assignments for you (step 1.6 and step 4).
  Contributor alone can create resources but can't assign roles.
- The resource providers registered on the subscription: `Microsoft.CognitiveServices`,
  `Microsoft.ContainerRegistry`, `Microsoft.Insights` and `Microsoft.OperationalInsights`. Check with
  `az provider show -n Microsoft.CognitiveServices --query registrationState`.
- Model quota for `$MODEL` in `$LOCATION`. Quota is shared per subscription, so keep the capacity small.

**On your machine:** Azure CLI, azd, `jq`, `curl`.

```sh
az login && az account set -s <subscription>
az config set defaults.group=$RG                # safety net: az commands default to your resource group
azd config set auth.useAzCliAuth true           # azd uses your az login
azd extension install azure.ai.agents           # or: azd extension update azure.ai.agents
```

## 1. Azure setup (one time)

These steps use the settings of the working demo setup, read back from Azure. They weren't re-run from an empty
resource group.

### 1.1 Foundry resource

```sh
az cognitiveservices account create -g $RG -n $FOUNDRY -l $LOCATION \
  --kind AIServices --sku S0 --custom-domain $FOUNDRY --allow-project-management \
  --assign-identity --tags $TAG --yes
```

### 1.2 Project

```sh
az cognitiveservices account project create -g $RG -n $FOUNDRY --project-name $PROJECT -l $LOCATION
az cognitiveservices account project show -g $RG -n $FOUNDRY --project-name $PROJECT \
  --query identity.principalId -o tsv          # must print an ID (the project identity, used in 1.6)
```

### 1.3 Model deployment

```sh
az cognitiveservices account deployment create -g $RG -n $FOUNDRY \
  --deployment-name $MODEL --model-name $MODEL --model-version 2026-04-24 --model-format OpenAI \
  --sku-name GlobalStandard --sku-capacity 10
```

### 1.4 Container registry

```sh
az acr create -g $RG -n $ACR -l $LOCATION --sku Basic --tags $TAG
```

### 1.5 Tracing: Application Insights

```sh
az monitor log-analytics workspace create -g $RG --workspace-name $FOUNDRY-logs -l $LOCATION --tags $TAG
az monitor app-insights component create -g $RG --app $FOUNDRY-appinsights -l $LOCATION \
  --workspace $FOUNDRY-logs --tags $TAG
```

Then connect it to the project in the **Foundry portal**: project → **Tracing** (Observability) → connect
`$FOUNDRY-appinsights`. Foundry then passes `APPLICATIONINSIGHTS_CONNECTION_STRING` to the agent's container, and the
agent's collector sends traces there. Without the connection, the agent still works but sends no traces.

### 1.6 Roles

```sh
ME=$(az ad signed-in-user show --query id -o tsv)
FOUNDRY_ID=$(az cognitiveservices account show -g $RG -n $FOUNDRY --query id -o tsv)
ACR_ID=$(az acr show -g $RG -n $ACR --query id -o tsv)
PROJECT_MI=$(az cognitiveservices account project show -g $RG -n $FOUNDRY --project-name $PROJECT \
  --query identity.principalId -o tsv)

# You: create and call agents (data plane)
az role assignment create --assignee-object-id $ME --assignee-principal-type User \
  --role "Foundry User" --scope $FOUNDRY_ID
# The project identity: pull agent images from the registry
az role assignment create --assignee-object-id $PROJECT_MI --assignee-principal-type ServicePrincipal \
  --role AcrPull --scope $ACR_ID
```

Building in ACR (step 5) also needs ACR Tasks rights for you. Owner or Contributor on the resource group covers
them; otherwise ask for **Container Registry Tasks Contributor** on the registry. Role assignments can take a few
minutes to apply.

## 2. The agent code

The container must:
- listen with plain HTTP on port **8088**
- answer `GET /readiness` with `200`
- handle `POST /invocations`
- read `AZURE_OPENAI_ENDPOINT` and `MODEL_DEPLOYMENT_NAME`, and call the model with the agent identity
  (`hr_agent/identity.bal`)

This repo's files for azd:

| File | What it is |
|---|---|
| `azure.yaml` (repo root) | The agent service (name, protocol, CPU/memory, idle timeout, env vars) and the existing project |
| `hr_agent/Dockerfile.azd` | Builds the JAR inside Docker, then the runtime image. No `FROM --platform` (ACR rejects it) |
| `hr_agent/Dockerfile.azd.dockerignore` | What gets uploaded for the build: sources only |

For your own setup, change the project `endpoint:` and the service name in `azure.yaml`. `azure.yaml` must sit at
or above the agent folder, because azd rejects paths containing `..`.

## 3. azd environment (one time)

The gitignored `.azure/` folder holds the values that `azure.yaml` reads. `azd ai agent init` only reads from Azure
here and is used just to create that folder. It doesn't support Ballerina code, so it gets a placeholder image
that it never pulls. Run it outside the repo, because it writes `./$AGENT/` and runs `git add`.

```sh
cd ~/Documents/ballerina-agents-azure-foundry
PROJECT_ID=$(az cognitiveservices account project show -g $RG -n $FOUNDRY --project-name $PROJECT --query id -o tsv)

mkdir -p /tmp/azd-env && (cd /tmp/azd-env && azd ai agent init \
  --image $ACR.azurecr.io/$AGENT:placeholder --agent-name $AGENT \
  --project-id "$PROJECT_ID" --protocol invocations -e dev --no-prompt)
cp -R /tmp/azd-env/$AGENT/.azure .azure && rm -rf /tmp/azd-env

# The agent's settings (no keys)
azd env set HR_AGENT_MODEL_ENDPOINT "https://$FOUNDRY.services.ai.azure.com/openai/v1/"
azd env set HR_AGENT_MODEL_DEPLOYMENT $MODEL
# Build in your existing registry (so azd never creates one)
azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT $ACR.azurecr.io
azd env set AZURE_CONTAINER_REGISTRY_RESOURCE_ID "$(az acr show -g $RG -n $ACR --query id -o tsv)"
azd env set AZD_AGENT_SKIP_ACR false

azd ai agent doctor     # all checks pass, except "agents have not been deployed" before the first deploy
```

## 4. First deploy, then give the agent identity access to the model (one time)

```sh
azd deploy $AGENT --preview
azd deploy $AGENT
```

The first deploy creates the agent and its Entra identity. Give that identity access to the model:

```sh
AGENT_MI=$(azd env get-value AGENT_$(echo $AGENT | tr 'a-z-' 'A-Z_')_INSTANCE_IDENTITY_PRINCIPAL_ID)
az role assignment create --assignee-object-id $AGENT_MI --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" --scope $FOUNDRY_ID
```

Wait a few minutes for the role to apply before you test (step 6). Model calls fail with 401/403 until then.

## 5. Every release

```sh
azd deploy $AGENT --preview   # read-only diff against the latest version
azd deploy $AGENT             # upload, build in ACR (~5 min), create a version, wait until it's active
```

Each release gets a unique image tag (`azd-deploy-<unix time>`) and a new agent version. New sessions go to the
latest version.

**What else azd may change:** azd can grant the agent identity **Monitoring Metrics Publisher** on App Insights
(for Entra-authenticated telemetry), and the docs say it grants the agent identity **AcrPull** on the registry. In
the demo setup neither happened, because the project identity already had AcrPull. After your first deploy, check
with `az role assignment list -g $RG --include-inherited -o table`. To stop azd assigning roles:
`azd env set AZD_AGENT_SKIP_ROLE_ASSIGNMENTS true` (named in the extension's messages, not in the docs).

## 6. Verify

```sh
azd ai agent show $AGENT
azd ai agent invoke $AGENT '{"message":"How much leave do I have left?","employeeId":"E1001"}' \
  -p invocations --new-session                  # prints the session ID; later invokes reuse it
azd ai agent monitor $AGENT -s <session-id> -l 100   # expect "Model auth: agent identity"
```

To see the response headers, call the endpoint with `curl -D -` (see the README). Traces appear in App Insights
after a few minutes.

## 7. Roll back

There's no azd command. Point the endpoint at a known-good version (deletes nothing):

```sh
BASE=https://$FOUNDRY.services.ai.azure.com/api/projects/$PROJECT
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
curl -s -X PATCH "$BASE/agents/$AGENT?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/merge-patch+json" \
  -d '{"agent_endpoint":{"version_selector":{"version_selection_rules":[{"type":"FixedRatio","agent_version":"<N>","traffic_percentage":100}]},"protocol_configuration":{"invocations":{}}}}' \
  | jq -c .agent_endpoint.version_selector
```

While pinned, new deploys get **no traffic**. Use `"agent_version":"@latest"` to follow new deploys again.

## 8. Clean up

When you're done with a release:

```sh
az acr repository show-tags -n $ACR --repository $AGENT -o tsv          # list image tags
az acr repository delete -n $ACR --image $AGENT:<old-tag> --yes          # delete one you don't need
```

When the demo ends (check with the maintainers first):

```sh
az role assignment list -g $RG --include-inherited -o table      # note the IDs you created (1.6, 4, any by azd)
az role assignment delete --ids <assignment-id>                  # for each of them
az resource list -g $RG -o table                                 # everything you created
# Delete the agent and the resources in your resource group (not the group itself), then purge the Foundry
# resource so its name and quota are released:
az cognitiveservices account purge -g $RG -n $FOUNDRY -l $LOCATION
rm -rf .azure
```

Never use `azd down`, and don't run `azd ai agent delete` unless you mean to delete the whole agent.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| ACR build fails at once: `unable to understand line FROM --platform=...` | ACR Tasks rejects FROM flags. Use `Dockerfile.azd` (no `--platform`) |
| `relative path "../..." must not contain '..'` | Move `azure.yaml` to the agent folder or above it |
| Build step can't find the Dockerfile, or uploads a large `target/` | `Dockerfile.azd.dockerignore` must allow-list `Dockerfile.azd` and exclude `target/` |
| Model call 401/403 right after the first deploy | The agent identity's role (step 4) is missing or still applying |
| Model call 403 with `x-deny-reason: <foundry>.services.ai.azure.com:POST` | A guardrail was attached to the agent version in the portal (`rai_config`). Redeploy without it; azd versions don't carry one |
| `doctor` says "agents have not been deployed" | Normal before the first deploy from this environment. Ignore its "run `azd deploy`" hint |
| No traces in App Insights | App Insights not connected to the project (1.5), or ingestion delay of a few minutes |
| `azd-ai-agents-<date>.log` files appear | Extension debug logs. Gitignore them |
