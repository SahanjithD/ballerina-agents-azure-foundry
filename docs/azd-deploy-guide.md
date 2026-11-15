# Deploy the Ballerina agent with azd

Copy-paste guide for **path B**: azd builds the image in ACR and creates the agent version. Path A (a pre-built
image) is at the end. For why and the measurements, see [azd-deploy-evaluation.md](azd-deploy-evaluation.md).
Commands marked *(not run)* weren't run during the evaluation. Everything else was.

> **Safety (shared subscription):** never run `azd up`, `azd provision`, `azd down` or a bare `azd deploy`.
> Only `azd deploy bal-demo-agent`. The `infra:` block in `azure.yaml` is used only by provision.

## Prerequisites

- Azure CLI logged in to the subscription (`az login`), with azd using it
  (`azd config set auth.useAzCliAuth true`), or `azd auth login`
- azd with the Foundry agents extension: `azd extension install azure.ai.agents` (or `azd extension update azure.ai.agents`)
- On `rg-foundry-dasuns`: Foundry User on the project, and a Container Registry role on `acrdasunsdemo` that allows
  ACR Tasks (Contributor/Owner, or Container Registry Tasks Contributor). `azd ai agent doctor` checks the first.
- Existing resources only: project `ballerina-demo`, registry `acrdasunsdemo`, model deployment `gpt-5.5`. azd
  creates none of them.

## One-time setup

The repo already has `azure.yaml` (repo root), `hr_agent/Dockerfile.azd` and `hr_agent/Dockerfile.azd.dockerignore`.
You only need an azd environment: the gitignored `.azure/` folder that holds the values `azure.yaml` reads.

```sh
cd ~/Documents/ballerina-agents-azure-foundry
SUB=$(az account show --query id -o tsv)
PROJECT_ID=/subscriptions/$SUB/resourceGroups/rg-foundry-dasuns/providers/Microsoft.CognitiveServices/accounts/foundry-dasuns-demo/projects/ballerina-demo

# 1. Create the environment. init only reads from Azure; it's used here just to write .azure/.
#    Run it outside the repo: it writes ./bal-demo-agent/ and runs `git add`.
mkdir -p /tmp/azd-env && (cd /tmp/azd-env && azd ai agent init \
  --image acrdasunsdemo.azurecr.io/bal-demo-agent:v6 --agent-name bal-demo-agent \
  --project-id "$PROJECT_ID" --protocol invocations -e bal-azd --no-prompt)
cp -R /tmp/azd-env/bal-demo-agent/.azure .azure && rm -rf /tmp/azd-env

# 2. The agent's settings (same as deploy.sh; no keys, since the agent is keyless).
azd env set HR_AGENT_MODEL_ENDPOINT "https://foundry-dasuns-demo.services.ai.azure.com/openai/v1/"
azd env set HR_AGENT_MODEL_DEPLOYMENT gpt-5.5

# 3. Use the existing registry (so azd never creates one) and build images.
azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT acrdasunsdemo.azurecr.io
azd env set AZURE_CONTAINER_REGISTRY_RESOURCE_ID "$(az acr show -n acrdasunsdemo -g rg-foundry-dasuns --query id -o tsv)"
azd env set AZD_AGENT_SKIP_ACR false

# 4. Check.
azd ai agent doctor
```

`doctor` should pass. A first run may report "1 of 1 agents have not been deployed". Ignore its "run `azd deploy`"
fix and use the per-release command below.

## Every release

```sh
azd deploy bal-demo-agent --preview   # read-only diff against the latest version
azd deploy bal-demo-agent             # upload hr_agent/, build in ACR (~5 min), create + activate a version
```

The image gets a unique tag (`azd-deploy-<unix time>`). The endpoint sends 100% of traffic to `@latest`, so the new
version serves new sessions as soon as it's active.

### What azd may change besides the version

- **Roles.** azd's deploy step can grant the agent identity **Monitoring Metrics Publisher** on the App Insights
  component, so Foundry can send the agent's telemetry with Entra auth (the extension calls this "Granting agent
  identity access to Application Insights"). The docs also say it grants the agent identity **AcrPull** on the
  registry. In our setup **neither happened**: images are pulled with the project identity's AcrPull on the resource
  group, and traces use the App Insights connection string. After a first deploy in a new setup, check:
  `az role assignment list -g rg-foundry-dasuns --include-inherited -o table`. If you manage roles yourself,
  `azd env set AZD_AGENT_SKIP_ROLE_ASSIGNMENTS true` turns this off. That switch is named in the extension's
  messages, not in the Learn docs. *(not run)*
- **Guardrails.** A version deployed from `azure.yaml` has no agent-level `rai_config`. A guardrail attached in
  the portal is dropped on the next deploy (with `deploy.sh` too).

## Verify

```sh
azd ai agent show bal-demo-agent
azd ai agent invoke bal-demo-agent '{"message":"How much leave do I have left?","employeeId":"E1001"}' \
  -p invocations --new-session            # prints the Session ID; later invokes reuse it
azd ai agent monitor bal-demo-agent -s <session-id> -l 100   # expect "Model auth: agent identity"
```

`invoke` doesn't print response headers. To see them, call the endpoint with `curl -D -` and
`&agent_session_id=<session-id>` (see the README).

## Roll back

There's no azd command. Point the endpoint at a known-good version (the documented way; it deletes nothing):

```sh
BASE=https://foundry-dasuns-demo.services.ai.azure.com/api/projects/ballerina-demo
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
curl -s -X PATCH "$BASE/agents/bal-demo-agent?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/merge-patch+json" \
  -d '{"agent_endpoint":{"version_selector":{"version_selection_rules":[{"type":"FixedRatio","agent_version":"<N>","traffic_percentage":100}]},"protocol_configuration":{"invocations":{}}}}' \
  | jq -c .agent_endpoint.version_selector
```

While pinned, new deploys (`azd` or `deploy.sh`) **don't get traffic**. To follow new deploys again, run the same
call with `"agent_version":"@latest"`. Existing sessions stay on the version they started on.

## Clean up

```sh
rm -rf .azure                                        # the local azd environment
az acr repository show-tags -n acrdasunsdemo --repository bal-demo-agent -o tsv   # list image tags
az acr repository delete -n acrdasunsdemo --image bal-demo-agent:<tag> --yes      # per unused tag (not run)
```

- Old agent versions: delete them only if you need to (`DELETE $BASE/agents/bal-demo-agent/versions/<N>?api-version=v1`,
  *not run*). Deleting isn't a rollback.
- Don't use `azd down` (it deletes provisioned resources) or `azd ai agent delete` (it deletes the whole agent).
- If a check after deploy shows a role azd added, remove it with `az role assignment delete --ids <assignment-id>`.

## Path A: azd with a pre-built image

`azd/prebuilt/azure.yaml` takes an image you build and push yourself. It needs the same azd environment, created
in `azd/prebuilt/` (`cp -R .azure azd/prebuilt/.azure`). Per release:

```sh
cd hr_agent && bal build && cd ..
az acr login -n acrdasunsdemo -g rg-foundry-dasuns
docker buildx build --platform linux/amd64 -t acrdasunsdemo.azurecr.io/bal-demo-agent:<new-tag> --push hr_agent
# edit azd/prebuilt/azure.yaml: image: acrdasunsdemo.azurecr.io/bal-demo-agent:<new-tag>
(cd azd/prebuilt && azd deploy bal-demo-agent)
```

This is the same work as `./deploy.sh <new-tag>` plus an edit, so prefer `deploy.sh` or path B.
