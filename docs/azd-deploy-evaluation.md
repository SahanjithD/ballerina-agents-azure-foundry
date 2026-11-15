# Deploying the Ballerina agent with azd: evaluation

Tested on 2026-11-15 with azd 1.37.3, `azure.ai.agents` 1.1.0, main's code (keyless `identity.bal`), against
`foundry-dasuns-demo` / `ballerina-demo` / `acrdasunsdemo` in `rg-foundry-dasuns`. Both paths were deployed as real
versions of `bal-demo-agent`, tested, and then the endpoint was rolled back to version 7.

## Verdict

| Path | Works? | Easier than deploy.sh? | Why |
|---|---|---|---|
| **A: azd + pre-built image** | Yes (v8) | **No** | You still build and push the image yourself (the same steps as `deploy.sh`), and also edit `image:` in `azure.yaml` for every release. azd only replaces the create-version + poll calls that `deploy.sh` already makes. |
| **B: azd container deploy (remote build)** | Yes (v9), after two fixes | **Yes, per release** | One command, `azd deploy bal-demo-agent`, and no local Ballerina, Docker, `jq` or `.env`. The image is built in ACR Tasks. The cost: a slower release (~5.5 min, every time) and a second Dockerfile. |

**Recommendation:** use **path B** if you want azd. Keep `deploy.sh` for fast local iteration, since it reuses
local Docker layer caches. Path A isn't worth adopting on its own. azd's `invoke`, `monitor`, `sessions` and `doctor`
commands are useful with any of the three ways of deploying.

## Comparison

| | deploy.sh (REST) | A: azd, pre-built image | B: azd, container (remote build) |
|---|---|---|---|
| Who builds the JAR | You (`bal build`, inside the script) | You (`bal build`) | ACR Tasks (Ballerina stage in `Dockerfile.azd`) |
| Who builds the image | You (local `docker buildx`) | You (local `docker buildx`) | ACR Tasks (`azd deploy` uploads `hr_agent/`) |
| Who pushes | You (inside the script) | You | azd / ACR Tasks |
| Who creates the version | The script (REST `POST /agents/.../versions`) | azd | azd |
| Waits for `active` | Yes (polls) | Yes (polls) | Yes (polls) |
| Files needed | `deploy.sh`, `.env`, `Dockerfile` | `azd/prebuilt/azure.yaml`, `.azure/<env>/.env`, `Dockerfile` | `azure.yaml` (repo root), `.azure/<env>/.env`, `Dockerfile.azd`, `Dockerfile.azd.dockerignore` |
| Commands per release | 1: `./deploy.sh v7` | 4 + an edit: `bal build`, `az acr login`, `docker buildx … --push`, edit `image:`, `azd deploy bal-demo-agent` | 1: `azd deploy bal-demo-agent` |
| Release time (measured) | ~1 min plus the local build (minutes with a cold cache) | 61 s for azd + the local build (7.5 min cold here) | 5 min 31 s (remote build 4 min 44 s, version 44 s) |
| Image tag | You choose (`v7`) | You choose (`azd-a1`) | azd chooses (`azd-deploy-<unix time>`), unique, never `latest` |
| Local tools | bal, Docker, az, jq, curl | bal, Docker, az, azd | az, azd |
| One-time setup | Done (the script exists) | `azd ai agent init --image …` + edit `azure.yaml` + 2 `azd env set` | Write `azure.yaml` + `Dockerfile.azd` by hand + 5 `azd env set` (init can't scaffold Ballerina) |
| Roles azd assigned | n/a | **None** | **None** |
| Resources azd created | n/a | **None** (agent version 8 only) | **None** (agent version 9, image tag, ACR QuickRun history) |
| Developer roles checked | n/a | Foundry User, role-assignment write on the project | the same + a Container Registry role on the ACR |
| Cost notes | Local build only | Local build only | ACR Tasks bills per build-second (~4–5 min per release); each release adds an image of the same size to the registry |

### What the BEFORE/AFTER snapshots showed

Each deploy was bracketed by a snapshot covering resources in `rg-foundry-dasuns`, model deployments, project and
account connections, role assignments at the RG, Foundry account, project, ACR and App Insights scopes, every role
held by the agent identity, the project identity and me, App Insights tags, ACR tags and runs, and the agent.

| Step | Diff |
|---|---|
| `azd ai agent init` | Nothing in Azure (only GETs and Resource Graph queries) |
| Path A deploy | Agent version 8 (image `azd-a1`). Nothing else. |
| Path B, 1st try | Nothing (failed locally: `..` in the service path) |
| Path B, 2nd try | ACR QuickRun `ca1` failed (scanner, see below). Nothing else. |
| Path B, 3rd try | Agent version 9, tag `azd-deploy-1794747449`, QuickRun `ca2` succeeded. Nothing else. |
| Rollback | Endpoint selector `@latest` → `7` |

**Role assignments created by azd: none.** No role assignment ID to record or clean up. The docs say `azd deploy`
always grants AcrPull to the agent identity, and the extension's code also has a deploy step "Granting agent
identity access to Application Insights" (Monitoring Metrics Publisher, so the agent identity can send
Entra-authenticated telemetry). Neither ran here. Images were pulled with the project identity's existing AcrPull
on the resource group, and traces kept flowing through the App Insights connection string.

### Tests (both paths)

One session per path: one HR question through `azd ai agent invoke`, then one follow-up in the same session with
`curl` to read the headers.

- Answer: "Annual 14, Sick 7, Casual 7". Follow-up: "You have 7 sick days remaining" (session memory works).
- Headers: `x-platform-server: bal-foundry-host/0.1.0 (ballerina/2201.14.0)`, `x-agent-session-id`, `x-request-id`
  (gateway ID + container ID).
- Keyless: logs show `Model auth: agent identity`, `Model token proxy listening` and `Fetched agent identity token`.
- Tracing: `post /invocations`, `execute_tool getLeaveBalance` and `chat gpt-5.5` spans in App Insights for the
  invocation's trace ID.
- Cold start: ~11–13 s (readiness ~5 s, container ~4.5 s).

## Problems hit

1. **ACR Tasks rejects `FROM --platform=…`.** Its dependency scanner reads `FROM <image> [AS <alias>]` and fails on
   any flag ("unable to understand line"; `Azure/acr-builder` `scan/dependencies.go`). Main's `Dockerfile` has it
   on the Go stage, so it can't be built remotely. Fix: `Dockerfile.azd` without the flag (ACR builders are amd64).
2. **azd rejects service paths containing `..`**, so path B's `azure.yaml` lives at the repo root
   (`project: hr_agent`).
3. **azd's remote-build packer uses `<Dockerfile>.dockerignore` first** and doesn't add the Dockerfile on its own,
   so `Dockerfile.azd.dockerignore` must allow-list `Dockerfile.azd`. It also keeps the ~100 MB local JAR out of
   the upload.
4. **`azd ai agent init` doesn't support Ballerina source.** With `--image` it works, but it writes into a new
   `./<agent-name>/` folder, runs `git add` itself, defaults to 0.5 vCPU / 1 GiB, sets no idle timeout or env
   vars, and stores `AZURE_OPENAI_ENDPOINT` as the account URL (not `/openai/v1`). The agent's values therefore
   use separate `HR_AGENT_*` names in the azd env.
5. **`azd deploy --preview` leaves things out.** It says it doesn't preview dependencies (role assignments), it
   showed no build step for path B, and it didn't mention that `rai_config` would be dropped (next item).
6. **Version 7's guardrail is lost on redeploy.** Version 7 has an agent-level `rai_config` (RAI policy
   `Guardrails629`, attached on 2026-11-12 at 05:54 UTC, the moment v7 was created). Versions 8 and 9 have none.
   `deploy.sh` would drop it too, since it never sends `rai_config`.
7. **Version 7 fails model calls.** With that `rai_config`, the sandbox egress proxy denies the model call: `403`,
   `x-deny-reason: foundry-dasuns-demo.services.ai.azure.com:POST`, so `/invocations` returns 500. Versions 8 and 9
   (same identity and code, no `rai_config`) work. This predates the evaluation, but it means rolling back to 7
   rolls back to a broken version.
8. **No azd rollback command.** Rollback is the REST/SDK endpoint version selector (see the guide).
9. The extension writes debug logs (`azd-ai-agents-<date>.log`) into the working directory. They're gitignored now.
10. `bal build` in Ballerina 2201.14 doesn't run tests, so a build stage needs no placeholder model settings.
