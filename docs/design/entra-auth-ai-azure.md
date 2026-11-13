# Design: Microsoft Entra ID (keyless) authentication for `ballerinax/ai.azure`

**Status:** draft, in progress (research, requirements and options done; final design to follow)
**Audience:** Ballerina AI team (ballerina/ai and ballerinax/ai.* maintainers)

<!-- Sections 1, 2 and 4–9 are filled in at later checkpoints. -->

## 1. Summary

_To be written after the design is agreed._

## 2. Problem and requirements

### 2.1 Problem

`ballerinax/ai.azure` can only authenticate with an API key (§3.1). Teams that disable keys
(`disableLocalAuth: true`), or that run on Azure compute with a managed identity, can't use it without workarounds.
The same applies to AKS workload identity, Foundry hosted agents, service principals on-prem, and developers
signed in with `az login`. Users can't work around it themselves:

- `http:ClientConfiguration.auth` has no token-provider hook (H1).
- The OAuth2 config only fits a client secret, and it panics at init (H4, §3.3).
- A provider can't be wrapped in pure Ballerina (A8).

The only option today is a local proxy that swaps headers, like `hr_agent/identity.bal`, copied into every app.
Python and Java users write `DefaultAzureCredential()`.

### 2.2 Functional requirements

| # | Requirement | Priority |
|---|---|---|
| FR1 | Keyless auth for **all** `ai.azure` entry points: `OpenAiModelProvider` (chat and responses, v1 and legacy), `EmbeddingProvider` (v1 and legacy) and `AiSearchKnowledgeBase` (search and index clients). | Must |
| FR2 | Existing code that passes an API key keeps compiling and behaving the same. | Must |
| FR3 | Credential sources: **managed identity** (App Service-style endpoint, which also covers Foundry hosted agents and Container Apps; plus IMDS for VMs, VMSS and AKS node identity), **workload identity** (AKS, federated token file), **service principal with client secret**, **Azure CLI** (developer machines), **static token**, and a **user-supplied token provider** (escape hatch). | Must |
| FR4 | Service principal with **certificate**. Many organisations forbid secrets for service principals. It ships in phase 2, but the phase-1 API must **reserve room** for it, so that adding it is non-breaking (§4.6). | Should (phase 2; API slot in phase 1) |
| FR5 | A **default chain** for "works here and in Azure" without code changes: Environment → Workload identity → Managed identity → Azure CLI. It follows azure-identity's rules: unavailable → next, failure → stop, and remember the source that worked (M1, M2). It can be narrowed to production-only or developer-only sources (like `AZURE_TOKEN_CREDENTIALS`, M3). | Must |
| FR6 | The default **scope** is **derived from the endpoint URL** (§4.7): for example, project endpoint → `ai.azure.com` (§3.6 Observed), Search → `search.azure.com`. It can always be overridden per client. | Must |
| FR7 | Credential settings can be expressed as **plain data** (records, enums, strings), so they work as `configurable` values in Config.toml and as forms in WSO2 Integrator. Objects and functions are only the pro-code escape hatch. | Must |
| FR8 | User-assigned managed identity can be selected by client ID, defaulting to `AZURE_CLIENT_ID` as azure-identity does. | Must |
| FR9 | One credential instance can be **shared** by the model, embedding and knowledge-base clients, with one cache per scope. | Should |
| FR10 | Sovereign clouds: the authority host and scope can be overridden. | Should |
| FR11 | The credential type is not specific to AI: other Azure connectors (Search, Key Vault, Storage…) can reuse it later. | Should |

### 2.3 Non-functional requirements

| # | Requirement |
|---|---|
| NF1 | **Isolated:** the credential and the provider stay `isolated` and are safe under concurrent strands. |
| NF2 | **Caching:** refresh 300 s before expiry, or at `refresh_on` when present; at most one refresh in flight per scope; retry a failed refresh at most every 30 s; keep serving the cached token while it is still valid (M8). |
| NF3 | **No panics, no network calls during construction.** A temporary Entra outage must not crash the program (unlike H4). Errors surface as `ai:Error` on the first call. |
| NF4 | **Error messages** name the credential and the cause. A chain error lists every attempted source and why it was skipped. Service 401/403 responses mention the audience/role as hints. Errors are typed so callers can tell "no credential available" from "denied". |
| NF5 | **Secrets never leak:** tokens, client secrets, assertions and `IDENTITY_HEADER` values are never logged, put in error messages, or added to spans. Token endpoint error bodies are reduced to the `error`/`AADSTS` code and description. |
| NF6 | **TLS and proxies:** token requests to Entra use the same `secureSocket` / `proxy` settings as the service client. This covers Foundry's `SSL_CERT_FILE` CA bundle and corporate proxies. The local metadata endpoints (IMDS, `IDENTITY_ENDPOINT`) are never sent through a proxy. |
| NF7 | **Observability:** log at debug level which source was selected and how long the token lives (never the token itself). Token fetch failures appear as errors on the existing model and embedding spans. |
| NF8 | **Testable without Azure:** every endpoint can be overridden (authority host, IMDS / identity endpoint, CLI command), so unit tests run against mock services. A static or fake credential is available for tests. |
| NF9 | **Bounded startup:** probing the chain takes at most about 1–2 s on machines without IMDS (azure-identity uses a 1 s probe, M7). The Azure CLI call times out after 10 s. |
| NF10 | **Non-breaking:** shipped as a minor release of `ai.azure`. |

### 2.4 Out of scope (v1)

- Interactive or user-delegated flows: browser, device code, username/password, on-behalf-of.
- IDE and other CLI credentials: VS Code, IntelliJ, PowerShell, azd, the WAM broker, and the shared token cache.
- Managed-identity flavours with tiny reach: Service Fabric, Azure Arc, Azure ML, Cloud Shell. Arc may be revisited for on-prem.
- Continuous access evaluation (CAE) and claims challenges, and persisting tokens to disk.
- Changing the other `ai.*` providers. §7 only states what this design means for them.
- Foundry-specific features (agent identity blueprints, OBO for agents).

## 3. Verified facts and open questions

Source snapshots used for every code reference below:

| Repo (github.com/ballerina-platform) | Commit | Package version |
|---|---|---|
| module-ballerinax-ai.azure | `5fd8ed1` (2026-10-15) | 1.5.1 (identical to the published 1.5.1 bala) |
| module-ballerina-http | `d710c4a` (2026-11-12) | 2.18.3-SNAPSHOT (experiments ran on 2.18.2) |
| module-ballerina-oauth2 | `604caa6` (2026-10-20) | 2.15.1-SNAPSHOT |
| module-ballerina-jwt | `29a35f5` | 2.15.2-SNAPSHOT |
| module-ballerina-ai | `f64e392` (2026-11-11) | 1.17.0-SNAPSHOT |
| ai.anthropic / ai.aws.bedrock / ai.googleapis.vertex / ai.openrouter | `df74901` / `8184e48` / `862f555` / `9633195` | 1.4.0 / 1.0.1 / 1.0.3 / 1.0.3 |
| Generated connectors (published balas) | — | azure.openai.chat 4.0.0, azure.openai.responses 1.0.0, azure.openai.embeddings 1.0.2, azure.ai.search(.index) 1.0.2, ballerinax/aws 1.1.0 |

Microsoft sources: azure-identity Python `main` (1.27.x, MSAL Python 1.39.0) and azure-identity Java `main`
(1.20.0-beta.1; latest Maven release 1.19.0), plus the Microsoft Learn pages linked inline.

Experiments ran locally on Ballerina 2201.14.0 against mock endpoints only (no Azure). Their source is in
[`entra-auth-experiments/`](entra-auth-experiments/).

### 3.1 `ai.azure` today

| # | Fact | Source |
|---|---|---|
| A1 | Every request authenticates with a static `api-key` header. `ConnectionConfig` has no `auth` field. | `ballerina/types.bal` (ConnectionConfig) |
| A2 | `OpenAiModelProvider.init(serviceUrl, string apiKey, deploymentId, ...)` | `model-provider.bal:87-96` |
| A3 | The model provider has four wire paths. Chat v1 and Responses v1 go through the generated connectors with `auth: {api-key}`. Chat legacy and Responses legacy go through a raw `http:Client` with a per-call `{"api-key": apiKey}` header. | `provider_utils.bal:523-524, 383-385`; `responses_utils.bal:355-356, 310-311` |
| A4 | `EmbeddingProvider.init(serviceUrl, string accessToken, apiVersion, deploymentId, ...)`. The parameter is named and labelled **"Access Token" but is sent as `api-key`**, so the existing name is misleading. v1 uses a raw client with a per-call header; legacy uses the generated `azure.openai.embeddings` with `auth: {apiKey}`. | `embedding_provider.bal:62-67, 183-186, 237` |
| A5 | `AiSearchKnowledgeBase.init(serviceUrl, string apiKey, index, ...)` passes `{"api-key": apiKey}` as a per-call header on every `azure.ai.search` / `azure.ai.search.index` call. Those connectors' `ConnectionConfig` has **no `auth` field**. | `azure_ai_search_knowledgebase.bal:113, 141, 154, 214, 299, 346, 383`; `azure.ai.search` 1.0.2 `types.bal:129` |
| A6 | Generated `azure.openai.{chat,responses,embeddings}` take `auth: http:BearerTokenConfig\|ApiKeysConfig` (required). A bearer token is passed into `http:ClientConfiguration.auth` as a **static** token. | `azure.openai.chat` 4.0.0 `types.bal:138`, `client.bal:31-39` |
| A7 | **Experiment E-H:** with a static `BearerTokenConfig`, the configured token **overrides** a per-call `Authorization` header. With `ApiKeysConfig`, an `api-key` header is **always** sent, even an empty one. So a refreshing token cannot be attached *cleanly* through today's generated connectors. (Azure OpenAI itself tolerates the stray empty `api-key` when a valid Bearer is present: Q2 in §3.8.) | [`headers/main.bal`](entra-auth-experiments/headers/main.bal); http `auth_client_bearer_token_auth_handler.bal:34` (`setHeader` overwrites) |
| A8 | `ai:ModelProvider.generate` is dependently typed and implemented as `external` in every provider. A pure-Ballerina wrapper that delegates to an inner provider does not compile (`a function with a non-'external' function body cannot be a dependently-typed function`). Users therefore can't fix auth by wrapping a provider. | ai `model-provider.bal:117-133`; [`dtcheck/main.bal`](entra-auth-experiments/dtcheck/main.bal) |

### 3.2 `ballerina/http` and `ballerina/oauth2`

| # | Fact | Source |
|---|---|---|
| H1 | `http:ClientAuthConfig = CredentialsConfig\|BearerTokenConfig\|JwtIssuerConfig\|OAuth2GrantConfig`. It is closed: there is **no custom token-provider / custom handler hook**. The internal `ClientAuthHandler` union is non-public, and `enrichRequest` panics on any other type. | http `auth_types.bal:97,100`; `http_secure_client.bal:232,238-254` |
| H2 | When `auth` is set, `Authorization` is computed **per request**, on every remote method. OAuth2 calls `generateToken()` each time and serves it from cache. | `http_secure_client.bal:55-160`; `auth_client_oauth2_handler.bal:36-38` |
| H3 | OAuth2 grants supported: client_credentials, password, refresh_token, jwt-bearer. | oauth2 `client_oauth2_provider.bal:155,227-237` |
| H4 | `ClientOAuth2Provider.init` **fetches a token eagerly and panics on failure**. `http:Client\|error c = new (...)` does not catch it (experiment E9: process exits with the error, stack through `ClientOAuth2Provider:init`). | `client_oauth2_provider.bal:201-209`; [`panictest/main.bal`](entra-auth-experiments/panictest/main.bal) |
| H5 | The token cache refreshes at `expires_in - clockSkew`, and `clockSkew` **defaults to 0** (no early refresh). The refresh is single-flight under `lock`: in E5, 20 concurrent calls after expiry made 1 token fetch. | `client_oauth2_provider.bal:40,246-254,683-692`; [`authexp/main.bal`](entra-auth-experiments/authexp/main.bal) E4/E5 |
| H6 | The client-credentials grant **requires a non-empty `clientSecret`**. It sends it as Basic auth (default) or in the body; client authentication can't be turned off. Values are not URL-encoded. | `client_oauth2_provider.bal:315-317,569-615`; `oauth2_commons.bal:73-76`; E2, E8 |
| H7 | `optionalParams` can inject `client_assertion` / `client_assertion_type` (E1). But the config is `cloneReadOnly()` at init, so the assertion is **frozen**: it can't be re-signed or re-read from a rotating file. The dummy secret is still sent alongside it. | `client_oauth2_provider.bal:202`; E1, E5 |
| H8 | The JWT-bearer grant sends `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=…` (RFC 7523 §2.1). That is **not** Entra's client-assertion flow, which is `grant_type=client_credentials` + `client_assertion`. | `client_oauth2_provider.bal:403,412`; E3; [Entra client-creds flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow) |
| H9 | There is no 401 handling. A 401 is returned as-is; `retryConfig.statusCodes:[401]` re-sends the same cached token. | E6, E7; `http_client_endpoint.bal:648-661` |
| H10 | `ballerina/jwt` can't build an Entra certificate assertion. The header supports only `alg/typ/cty/kid` (no `x5t#S256`), and the only algorithms are RS/HS (no PS256). `crypto:signRsaSsaPss256` exists, so it is buildable by hand. | jwt `jwt_commons.bal:20,64-69`; `jwt_issuer.bal:30-39`; crypto 2.12.2 `sign_verify.bal:94,154` |

### 3.3 Credential sources → can `ballerina/http` + `oauth2` do it?

| Source | Wire protocol | Fits http/oauth2 config? | Why |
|---|---|---|---|
| Service principal + client secret | `POST {authority}/{tenant}/oauth2/v2.0/token`, `client_credentials`, `scope=<res>/.default` | **Yes, with caveats** | `OAuth2ClientCredentialsGrantConfig` works (E1/E2). Caveats: init panics if Entra is unreachable (H4), `clockSkew` must be set (H5), values aren't URL-encoded (H6). |
| Service principal + certificate | `client_credentials` + `client_assertion` (JWT signed with cert, `x5t#S256`) | **No (custom)** | A fresh signed assertion is needed per fetch, but `optionalParams` is frozen (H7), a dummy secret is forced (H6), and jwt can't set `x5t` (H10). |
| Workload identity (AKS, federated) | `client_credentials` + `client_assertion` = `AZURE_FEDERATED_TOKEN_FILE` contents | **No (custom, small)** | The file rotates, so it must be re-read per fetch; `optionalParams` is frozen (H7); a dummy secret is forced (H6). |
| Managed identity, IMDS | `GET 169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=…`, `Metadata: true` | **No (custom)** | It is a GET with a custom header, not an OAuth2 token request (oauth2 only POSTs: `OAuth2Client.java:314,324`). |
| Managed identity, App Service-style (App Service, Container Apps, **Foundry hosted agents**) | `GET {IDENTITY_ENDPOINT}?api-version=2019-08-01&resource=…[&client_id=…]`, `X-IDENTITY-HEADER` | **No (custom)** | Same as IMDS. `expires_on` is an epoch **string**; oauth2's parser expects an int `expires_in` (`client_oauth2_provider.bal:636-642`). |
| Azure CLI (developer machine) | subprocess `az account get-access-token --output json --resource <res> [--tenant …]` | **No (custom)** | It is a process call, not HTTP. |
| Static token / user-supplied provider | — | Static: **yes** (`BearerTokenConfig`). Provider: **no** | No callback hook (H1). |

Conclusion: only the client-secret path is pure configuration, and even that has the init-panic caveat. Every
other source needs a small token-credential object (get token → cache → refresh) and a way to attach its token per
request.

### 3.4 How Microsoft's azure-identity behaves (the reference we compare against)

| # | Fact | Source |
|---|---|---|
| M1 | `DefaultAzureCredential` order. Python: Environment → WorkloadIdentity → ManagedIdentity → SharedTokenCache (Windows) → VS Code → Azure CLI → PowerShell → azd → Broker (InteractiveBrowser excluded). Java: the same minus SharedTokenCache, plus IntelliJ. | py `_credentials/default.py:263-313`; java `DefaultAzureCredentialBuilder.java:378-394` |
| M2 | Chain rule: "unavailable" → try the next credential; any other failure → **stop** and raise. Once a credential succeeds, the chain **remembers it**. | py `chained.py:131-159`; java `ChainedTokenCredential.java:129-144,175-189` |
| M3 | `AZURE_TOKEN_CREDENTIALS=dev\|prod\|<credential name>` narrows the chain. `prod` = Environment, WorkloadIdentity, ManagedIdentity. | py `_internal/utils.py:186-245`; java `DefaultAzureCredentialBuilder.java:329-370` |
| M4 | EnvironmentCredential: `AZURE_TENANT_ID` + `AZURE_CLIENT_ID` + one of `AZURE_CLIENT_SECRET` / `AZURE_CLIENT_CERTIFICATE_PATH` (+`_PASSWORD`) / `AZURE_USERNAME`+`AZURE_PASSWORD`. `AZURE_AUTHORITY_HOST` overrides `login.microsoftonline.com`. | py `environment.py:63-86`, `_constants.py:47-56` |
| M5 | Workload identity: `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_FEDERATED_TOKEN_FILE`. Python re-reads the file at most every 600 s; Java re-reads it on every assertion. | py `workload_identity.py:41-46,93-95`; java `WorkloadIdentityCredential.java:146-165` |
| M6 | Managed identity source detection, in order: Service Fabric (`IDENTITY_SERVER_THUMBPRINT`) → App Service (`IDENTITY_ENDPOINT`+`IDENTITY_HEADER`) → Arc → Azure ML (`MSI_ENDPOINT`+`MSI_SECRET`) → Cloud Shell (`MSI_ENDPOINT`) → IMDS. The resource is the scope minus `/.default`, and exactly one scope is allowed. | py `managed_identity.py:82-143`, `_internal/__init__.py:26-41` |
| M7 | IMDS inside a chain is probed once with a 1 s timeout; no response means "unavailable". Standalone, it retries 5× with backoff on 404/410/429/5xx. | py `imds.py:25-56,105-151` |
| M8 | Caching: refresh when ≤ 300 s remain or at `refresh_on` (= `expires_in/2` when the lifetime is ≥ 2 h). Retry a failed refresh at most every 30 s, and keep serving the still-valid token if a refresh fails. Java's `AccessTokenCache` is single-flight (lock). Python's sync pipeline policy is **not** locked. | py `_constants.py:10-11`, `utils.py:36-66`, `get_token_mixin.py:131-137`; java `AccessTokenCache.java:80-151,260-310` |
| M9 | Azure CLI: `az account get-access-token --output json --resource <res> [--tenant …]`, 10 s timeout, run with a fixed cwd. The CLI is "unavailable" if `az` isn't found or isn't logged in. It prefers `expires_on` (epoch) over `expiresOn` (local time). | py `azure_cli.py:34-35,177-306` |
| M10 | Java azure-identity 1.19.0 pulls in `azure-core`, `azure-core-http-netty` (reactor-netty), `msal4j`, `msal4j-persistence-extension` and `jna-platform` at compile scope. | Maven Central `com.azure:azure-identity:1.19.0` POM |

### 3.5 Foundry hosted agents (one environment among many)

| # | Fact | Source |
|---|---|---|
| F1 | Each hosted agent gets its own Entra **agent identity**. Code gets tokens from the hosted-agent token service, and Microsoft's guidance is to use `DefaultAzureCredential` / `ManagedIdentityCredential`. The project's managed identity is not available to agent code. | [hosted-agent-token-service](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/hosted-agent-token-service), [agent-identity](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/agent-identity) |
| F2 | The token service uses **exactly the App Service contract**: `IDENTITY_ENDPOINT`, `IDENTITY_HEADER`, `api-version=2019-08-01`, `resource=` (not `/.default`), optional `client_id`, and a response with `expires_on` as a unix-time string. | same page |
| F3 | Calling the account endpoint directly needs *Cognitive Services OpenAI User* or *Foundry User* on the agent identity. Inference through the project endpoint is allowed by default. | [hosted-agent-permissions](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/hosted-agent-permissions) |
| F4 | So a generic App Service-style managed-identity source covers Foundry hosted agents. **No Foundry-specific code is needed.** | F2 + M6 |

### 3.6 Token audiences (scopes)

| Endpoint | Scope | Source |
|---|---|---|
| Azure OpenAI v1 (`…openai.azure.com/openai/v1`, `…services.ai.azure.com/openai/v1`) | `https://ai.azure.com/.default` (v1 page); `https://cognitiveservices.azure.com/.default` (starter kit). Docs show both. | [api-version-lifecycle](https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle); [starter kit](https://learn.microsoft.com/en-us/azure/developer/ai/get-started-azure-openai-starter-kit) |
| Foundry Models | "Tokens must be issued with scope `https://ai.azure.com/.default`" | [configure-entra-id](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/configure-entra-id) |
| Azure OpenAI legacy (`/openai/deployments/…?api-version=`) | Reference page names no scope; samples use `https://cognitiveservices.azure.com/.default` | [reference](https://learn.microsoft.com/en-us/azure/foundry/openai/reference) |
| Foundry project endpoint (`…/api/projects/<p>`) | `https://ai.azure.com/.default` | [sdk-overview](https://learn.microsoft.com/en-us/azure/foundry/how-to/develop/sdk-overview) |
| Claude on Foundry (`…services.ai.azure.com/anthropic/v1/messages`) | `https://ai.azure.com/.default`, `Authorization: Bearer`. Key auth uses `x-api-key`. | [use-foundry-models-claude](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/use-foundry-models-claude); [Anthropic: Claude in Foundry](https://platform.claude.com/docs/en/build-with-claude/claude-in-microsoft-foundry) |
| Azure AI Search data plane | `https://search.azure.com/.default`. The service must have RBAC enabled ("Role-based access control" or "Both"); the default is keys only. | [search-security-enable-roles](https://learn.microsoft.com/en-us/azure/search/search-security-enable-roles) |
| Sovereign clouds | Authority `login.microsoftonline.us` / `login.chinacloudapi.cn`; Gov AOAI uses `https://cognitiveservices.azure.us/.default` | py `_constants.py:34-36`; Azure Government docs |

**Observed (Q1, 2026-11-13).** These were read-only calls with an `az login` user token (role *Foundry User*)
against an `AIServices` account and a `gpt-5.5` deployment, each with one minimal prompt. Only the HTTP status
was recorded. The script is [`probe.sh`](entra-auth-experiments/probe.sh).

| Endpoint | Token for `cognitiveservices.azure.com` | Token for `ai.azure.com` |
|---|---|---|
| v1 chat, `<res>.openai.azure.com/openai/v1` | 200 | 200 |
| v1 chat, `<res>.services.ai.azure.com/openai/v1` | 200 | 200 |
| legacy chat, `/openai/deployments/<d>/chat/completions?api-version=2024-10-21` | 200 | 200 |
| project, `GET /api/projects/<p>/deployments?api-version=v1` | **401** "audience is incorrect (https://ai.azure.com)" | 200 |
| project, v1 chat `/api/projects/<p>/openai/v1/chat/completions` | **401** | 200 |

So account-level endpoints accept **both** audiences, while the **project endpoint accepts only `ai.azure.com`**.
This was not tested on a classic `kind: OpenAI` resource or in a sovereign cloud (see Q1b).

### 3.7 Existing Ballerina building blocks

| # | Fact | Source |
|---|---|---|
| B1 | No Azure identity / credential package exists on Ballerina Central (`azure.identity`, `azure_identity`, `azure.auth`, `entra`, `microsoft.entra`: 404). `ballerinax/azure.ad` is a Microsoft Graph user/group connector. | Central registry API, `bal search` |
| B2 | No Azure connector supports Entra or managed identity today. keyvault takes a static `BearerTokenConfig`; storage takes keys or SAS; cosmosdb takes a key or resource token; asb takes a SAS connection string; search takes an api-key header. | see the cross-provider appendix |
| B3 | **Precedent:** `ballerinax/aws` 1.1.0 ships `aws.auth`: `AuthConfig = Static\|Profile\|AssumeRole\|WebIdentity\|Sso\|Process\|DEFAULT_CREDENTIALS` plus an isolated `CredentialProvider` (Java AWS SDK v2 underneath, cached and refreshed). `ai.aws.bedrock` consumes it through a union-typed `auth` param. | `ballerinax/aws` 1.1.0 `modules/aws.auth/types.bal:19-37`, `credential_provider.bal:17-59`; bedrock `types.bal:25-34` |
| B4 | ballerina/ai has no shared model-provider auth abstraction. The only `auth` in ai types is for MCP/tools (`http:ClientAuthConfig\|AgentIdAuthConfig`). | ai `types.bal:173,200,223` |

### 3.8 Open questions

| # | Question | How to verify | Blocks |
|---|---|---|---|
| ~~Q1~~ | **Answered (§3.6 "Observed")**: account endpoints (v1 and legacy) accept both audiences; the project endpoint accepts only `ai.azure.com`. | `probe.sh` | — |
| Q1b | Does a classic `kind: OpenAI` resource, or a sovereign cloud, accept `ai.azure.com` tokens? | Same probe against a classic AOAI resource (none in our resource group) | Whether `ai.azure.com` can be the single default |
| ~~Q2~~ | **Answered**: Azure OpenAI returns 200 when a valid Bearer token comes with an **empty or placeholder `api-key`** header (v1 and legacy). An APIM front end with key-validation policies was not tested. | `probe.sh` | — |
| Q2b | Do APIM / gateway front ends reject a junk `api-key` sent next to a Bearer token? | Test against an APIM instance with `validate-azure-ad-token` and a subscription-key policy | Whether the "dummy api-key" shortcut is safe in general (it is not proposed) |
| Q3 | Does the Foundry token service ever return `expires_in` / `refresh_in`, or set other identity env vars? | Log env var **names** and response **keys** (never values) in a test agent | Parser robustness (we already accept both) |
| Q4 | `FOUNDRY_AGENT_INSTANCE_CLIENT_ID` (used by identity.bal, taken from Microsoft Agent Framework samples) is not in the Learn docs. Is passing it as `client_id` required, or is the default identity always the instance? | Compare token `oid`/`appid` claims with and without `client_id` (decode locally, don't log the token) | Whether the MI source needs a Foundry-specific env var at all |
| Q5 | Does Entra accept `client_assertion` sent alongside a dummy `client_secret` / Basic header? | Sandbox tenant curl | Only matters if we tried to reuse oauth2 for assertions (we don't propose that) |
| Q6 | RS256 + `x5t` vs PS256 + `x5t#S256` for certificate assertions: the Learn docs contradict each other. | Sandbox tenant | Certificate credential (later phase) |
| Q7 | Does `DEFAULT_CREDENTIALS` in `ballerinax/aws` cover the AgentCore runtime role / EKS Pod Identity? | Read AWS SDK 2.41.30 `DefaultCredentialsProvider`; test in AgentCore | Cross-provider note only |
| Q8 | Gov/China equivalent of `ai.azure.com` | Azure Government Foundry docs | Sovereign-cloud defaults |
| Q9 | Would a root package `ballerinax/azure` (option L2) make module resolution ambiguous for the existing `ballerinax/azure.*` packages? (`ballerinax/aws` coexists with `aws.s3` and others, which suggests not.) | Publish a test package pair to a local repository and build an app that imports both | L2 only |
| Q10 | What happens when an app pulls two `azure-core` versions (for example `ai.azure` with I2 plus `asb`)? Does it warn, pick one, or fail at runtime? | `bal build` an app depending on both; inspect the conflict warnings and the executable jar | I2 only |
| Q11 | Do `azure-identity` + msal4j work under `bal build --graalvm`? | Native-image spike with the slimmed jar set | I2 only |

## 4. Options and recommendation

The design has four independent decisions (axes). Each is compared on its own, then combined in §4.8.

### 4.1 Evaluation criteria

| # | Criterion | Why |
|---|---|---|
| EC1 | Covers the FR3/FR5 sources and behaves like azure-identity (M1–M9) | Users expect `DefaultAzureCredential` semantics |
| EC2 | **Dependency weight and conflict risk:** jar count and size; clashes with `ballerina/http`'s Netty and with other Azure connectors' `azure-core` pins | Every `ai.azure` user pays it |
| EC3 | **GraalVM:** `bal build --graalvm` keeps working | Ballerina supports native images; all current deps are `graalvmCompatible` |
| EC4 | **Maintenance:** who tracks protocol changes, version bumps and CVEs | Small team, many connectors |
| EC5 | **Consistency** with precedents: Microsoft's interface/implementation split, `ballerinax/aws` `aws.auth` (B3), `ai.googleapis.vertex` | Predictable for users and reviewers |
| EC6 | **Plain-data config** works in Config.toml and WSO2 Integrator (FR7) | Low-code users |
| EC7 | **Control** over TLS/proxy (NF6), errors (NF4) and secret hygiene (NF5) | Foundry `SSL_CERT_FILE`, corporate proxies |
| EC8 | **Testability** without Azure (NF8) | CI |
| EC9 | **Delivery cost:** repos touched, coordination, time to first release | We want this soon |

### 4.2 Axis L — where the credential lives

| | L1: inside `ai.azure` | L2: module in an umbrella package, `ballerinax/azure` → module `azure.identity` (the `aws`/`aws.auth` layout) | L3: separate package `ballerinax/azure.identity` |
|---|---|---|---|
| Reuse by other Azure connectors (FR11) | ✗ (they would have to depend on an AI package) | ✓ | ✓ |
| Matches Microsoft | ✗ | ~ (separate from service SDKs ✓, but packaged with other shared code) | ✓ (`azure-identity` is its own package; the `TokenCredential` interface sits in `azure-core`, java `TokenCredential.java:86`, py `credentials.py:72`, and every service SDK accepts any implementation) |
| Matches `ballerinax/aws` | ✗ | ✓ (package `aws` holds shared types such as `Region`; module `aws.auth` holds credentials) | ~ (separate from service connectors ✓, different packaging) |
| Release coupling | Tied to `ai.azure` releases | Own cadence | Own cadence |
| User import line | `ballerinax/ai.azure` | `import ballerinax/azure.identity;` | `import ballerinax/azure.identity;` (**identical**) |
| Name free on Central | n/a | `ballerinax/azure`: free (404) | `ballerinax/azure.identity`: free (404) |
| Delivery cost (EC9) | Lowest: one repo | New repo + `ai.azure` | New repo + `ai.azure` |

**Should we follow the separation?** Yes. Microsoft and `ballerinax/aws` both keep identity out of the service
SDKs, for the same reason that applies here: one credential, configured once, should work for every Azure client
in an app (FR9, FR11). Putting it inside `ai.azure` (L1) would make Key Vault or Storage depend on an AI package
later, or would force a second copy.

**L2 vs L3** is a packaging choice; user code is the same. **Recommend L3** (`ballerinax/azure.identity`):

- It is a 1:1 name match with Microsoft's package.
- Azure has no shared types that need an umbrella. `aws` has `Region` and `EndpointConfig`; Azure would only have
  the cloud authority hosts, which fit in the identity package.
- It avoids putting a new root package `ballerinax/azure` in front of ~15 existing `ballerinax/azure.*` package
  names. Whether that causes resolution ambiguity is unverified: **Q9**.

If the library team prefers the `aws` layout for symmetry, L2 is acceptable and users are unaffected.

### 4.3 Axis I — how tokens are acquired: pure Ballerina vs Java interop

| Criterion | I1: pure Ballerina (`http:Client`, `os:exec`, `crypto`) | I2: Java interop wrapping `azure-identity` (as `aws.auth` wraps AWS SDK v2) |
|---|---|---|
| EC1 coverage | The sources we choose to write: phase 1 is about 5 (MI ×2, WI, secret, CLI); certificate in phase 2. Exotic sources come only through the user token-provider escape hatch. | **Full `DefaultAzureCredential` parity on day one**, including certificate, Arc, Service Fabric, broker, CAE and MSAL's managed-identity rewrite (M6). |
| EC2 weight | **0 new jars.** Uses `http`, `crypto`, `os`, `time`, already in the dependency graph. | As published, `azure-identity` 1.19.0 resolves to about **48 jars / ~19 MB**¹: `azure-core`, Jackson, Reactor, **reactor-netty + Netty 4.2.19**, msal4j, JNA. Slimmed (JDK HTTP client instead of Netty, no persistence extension) it is about **15 jars / ~6.5 MB**, comparable to `aws.auth`'s **30 jars / 6.3 MB** (which also avoids Netty by using the Apache HTTP client). |
| EC2 conflicts | None. | `ballerina/http` ships **Netty 4.2.18**, while `azure-core-http-netty` 1.17 wants 4.2.19 (avoidable by dropping Netty). `asb` 3.10.1 pins `azure-core` 1.54.1 and `azure_cosmosdb` 4.5.0 pins 1.59.1; `azure-identity` 1.19 needs 1.61.0. **An app using `ai.azure` plus `asb` would carry two `azure-core` versions** (Q10). |
| EC3 GraalVM | Inherits `graalvmCompatible: true` from http, crypto, os and time (verified in their balas). | `asb` and `cosmosdb` declare `graalvmCompatible = true` with `azure-core`, so the core stack can work, but **`azure-identity` + msal4j are untested** under native image (Q11). JNA must be excluded. |
| EC4 maintenance | **We own the protocols.** They are small and stable: IMDS `2018-02-01`, App Service `2019-08-01`, the Entra v2 token endpoint, the `az` CLI JSON (M6, M9). Estimated ~800–1,200 lines including tests. | **Microsoft owns the protocols**; we own about 15–50 platform jars listed one by one in `Ballerina.toml` (as `asb` lists `azure-core`, `azure-json`, Jackson… explicitly), their version bumps and their CVEs, plus the Java glue (~300–500 lines). The `asb`/`cosmosdb` pins show these bumps lag. |
| EC5 consistency | Matches `ai.googleapis.vertex`, which signs its service-account JWT in Ballerina (§7). Doesn't match `aws.auth`'s technique. | Matches `aws.auth`. Note that `aws.auth` had a stronger reason: SigV4, STS, SSO and profile parsing are large. Azure's phase-1 sources are a few HTTP GET/POSTs. |
| EC7 control | **Full.** Token calls use a Ballerina `http:Client` with the same `secureSocket`/`proxy` as the service client, so Foundry's `SSL_CERT_FILE` bundle works the same way it does today (identity.bal). Errors and logs are ours. | The Java stack uses its own HTTP client and the **JVM truststore, which doesn't read `SSL_CERT_FILE`** ([JSSE guide](https://docs.oracle.com/en/java/javase/21/security/java-secure-socket-extension-jsse-reference-guide.html)), so the CA bundle and proxy must be bridged separately. MSAL logs through slf4j. |
| EC8 testability | Mock services in plain Ballerina tests (same style as `ai.azure`'s `tests/test_services.bal`). | Possible through env overrides (`AZURE_AUTHORITY_HOST`, `IDENTITY_ENDPOINT`), but tests run through a Java stack. |
| EC9 cost | Medium: we write and test the sources. | Medium: glue plus jar curation plus a GraalVM spike. |

¹ Approximate figures from a naive transitive resolution against Maven Central (test-scoped Netty dependencies
removed). Confirm with `mvn dependency:tree` before a final decision.

**Recommend I1 (pure Ballerina).** Phase 1 needs only a handful of small, stable HTTP protocols, and I1 adds no
jars, has no conflict surface and inherits GraalVM compatibility. Above all, it gives control over TLS/proxy
(EC7), which is exactly where Foundry's sandbox bit us. I2's real advantage is breadth (EC1). The escape hatch
(a user-supplied token provider) covers rare sources. **Revisit I2** if the scope grows to the broker,
interactive login or CAE, where MSAL's value is large.

### 4.4 Axis T — how `ai.azure` attaches the token

| | T1: give the generated connectors a token-provider auth type | T2: per-call `Authorization` on clients built with **no** `auth` config | T3: keep a local proxy (today's identity.bal) | T4: rebuild clients with a static `BearerTokenConfig` on refresh |
|---|---|---|---|---|
| Works today | ✗ `http:ClientAuthConfig` has no provider hook (H1); `ballerina/http` must change first, then the 3 connectors are regenerated | ✓ | ✓ | ✓ |
| Repos touched | http + 3 generated connectors + `ai.azure` | `ai.azure` only | per app | `ai.azure` |
| Refresh / concurrency | handled by http | handled by the credential (NF2) | in the proxy | racy (swap clients mid-flight), connection-pool churn |
| Cost | Highest; cross-team; benefits every connector long-term | Low | Extra hop and listener per app | Medium, fragile |

**How T2 works per path.**

- The **raw-client paths** (chat legacy, responses legacy, embeddings v1) already add `api-key` per call
  (A3, A4). Bearer mode just adds `Authorization: Bearer …` instead.
- The **Search** clients have no `auth` field and already take per-call headers (A5): same change.
- The **generated** v1 chat/responses and legacy embeddings connectors make `auth` *required*
  (`ConnectionConfig.auth`, A6), so they can't be built without it. There are two ways around this:
  - **T2a:** in bearer mode, use a raw `http:Client` for those three routes too. `ai.azure` already does this for
    the other three, binding to the generated record types (`chat:InlineResponse200 r = check client->post(...)`,
    `provider_utils.bal:383`). The generated v1 client only adds the header and serialises the payload
    (`azure.openai.chat` 4.0.0 `client.bal:41-59`), so nothing is lost.
  - **T2b:** keep the generated client with `auth: {api-key: ""}` and add `Authorization` per call. Q2 shows Azure
    OpenAI tolerates the stray header, but it is a hack and gateway behaviour is unknown (Q2b). **Rejected.**

**Recommend T2a now.** Propose T1 to the http team as a separate, non-blocking improvement (an
`http:BearerTokenProviderConfig`-style auth type), which would benefit every connector. When it lands, `ai.azure`
can move back to the generated clients with no API change.

### 4.5 Axis S — how users pass auth to `ai.azure`

_To be completed with the WSO2 Integrator findings (how it renders union-typed auth parameters and whether it
generates named arguments)._

### 4.6 Reserving room for certificates (FR4)

Certificate support is added in phase 2 without breaking phase-1 code, by making every extension point additive:

```ballerina
// azure.identity, phase 1
public type ClientSecretConfig record {|
    string tenantId;
    string clientId;
    string clientSecret;
    string authorityHost = AZURE_PUBLIC_CLOUD;
|};

// phase 2 adds a new record and a new union member: existing values still type-check
public type ClientCertificateConfig record {|
    string tenantId;
    string clientId;
    string certificatePath;            // PEM with private key, or PKCS#12
    string certificatePassword?;
    boolean sendCertificateChain = false;
    string authorityHost = AZURE_PUBLIC_CLOUD;
|};

public type CredentialConfig ManagedIdentityConfig|WorkloadIdentityConfig|ClientSecretConfig
        |AzureCliConfig|DEFAULT_CREDENTIAL /* phase 2: |ClientCertificateConfig */;
```

Rules that keep it non-breaking:

1. **Unions are inputs only.** Adding a member to a union that users *construct* never breaks them. Only code
   that exhaustively `match`es on it would break, and that code lives inside `azure.identity`.
2. **Records are closed, and new fields always get defaults.** That is how `sendCertificateChain` can arrive later.
3. **The object type is the stable contract.** `ai.azure` depends only on `TokenCredential` (one `getToken`
   method), so a new `ClientCertificateCredential` class is purely additive.
4. **Environment variables are reserved now.** In phase 1, if `AZURE_CLIENT_CERTIFICATE_PATH` is set *and no
   secret is*, the environment credential **fails** with "certificate credentials are not supported in this
   version". It doesn't silently fall through to a different identity (such as managed identity). In phase 2 the
   same configuration starts working, with no surprise identity switch.

### 4.7 Default scope derived from the endpoint URL (FR6)

`ai.azure` derives the scope when the user doesn't set one. The derivation lives in `ai.azure`, because only the
service knows its audience; Microsoft does the same, with audiences configured per service SDK.

| URL pattern | Default scope | Basis |
|---|---|---|
| path contains `/api/projects/` | `https://ai.azure.com/.default` | §3.6 Observed: the only accepted audience |
| host `*.search.windows.net` | `https://search.azure.com/.default` | Learn docs (§3.6) |
| host `*.openai.azure.com`, `*.cognitiveservices.azure.com`, `*.services.ai.azure.com` (non-project) | `https://cognitiveservices.azure.com/.default` | Observed: works on v1 and legacy. It is also the long-documented AOAI audience, so it is the safer default while **Q1b** (classic `kind: OpenAI` with `ai.azure.com`) is open |
| host `*.openai.azure.us` | `https://cognitiveservices.azure.us/.default` | Azure Government docs; sovereign search and `ai.azure` equivalents are open (Q8) |
| anything else (APIM `*.azure-api.net`, custom gateways) | **no default**: construction returns an error asking for an explicit `scope` | A silent wrong audience gives confusing 401s |

The scope can always be overridden per client. The derivation is a pure function, so it is unit-tested with a
table of URLs.

### 4.8 Recommendation

| Axis | Choice |
|---|---|
| L: where | **L3**: new package `ballerinax/azure.identity` (L2 acceptable) |
| I: how tokens are acquired | **I1**: pure Ballerina; revisit I2 only if the scope grows to broker/interactive/CAE |
| T: how they are attached | **T2a**: per-call header on raw clients; propose T1 to the http team separately |
| S: API shape | see §4.5 |
| Certificates | phase 2, with the slots reserved as in §4.6 |
| Scope | derived from the URL, overridable (§4.7) |

## 5. API design

_Checkpoint (d)._

## 6. Credential flows

_Checkpoint (d)._

## 7. Cross-provider notes

_Checkpoint (d)._

## 8. Security, testing, compatibility, rollout

_Checkpoint (d)._

## 9. What `hr_agent/identity.bal` becomes

_Checkpoint (d)._
