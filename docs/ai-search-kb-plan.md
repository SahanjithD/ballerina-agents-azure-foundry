# HR policy knowledge base with `azure:AiSearchKnowledgeBase`: plan and cost

Status: **plan only, nothing created yet.** It replaces `foundry-iq-plan.md`.
Scope: subscription `integration-rnd-001`, resource group `rg-foundry-dasuns`, **East US**. New resources are tagged
`RequestedBy=dasuns@wso2.com` (model deployments can't be tagged).

## Phase 0 findings

| # | Question | Finding | Evidence |
| --- | --- | --- | --- |
| 1 | Key needed by `init` | `init` always calls `indexesGet` (index name), or `indexesCreateOrUpdate` (`search:SearchIndex`), with an `api-key` header. **A query key can't do that.** Query keys are "read-only access, scoped to the documents collection", and "any read-only operation that returns … object definitions … requires an admin key" | `azure_ai_search_knowledgebase.bal:113-180` (ai.azure 1.5.1); Learn: search-security-api-keys |
| 1 | RBAC equivalent | **Search Index Data Reader can't read index definitions** (only query and retrieve). **Search Service Contributor** can manage objects, but "Owner, Contributor, and Search Service Contributor can retrieve admin keys", so it's effectively an admin key. The docs show a custom role adding `Microsoft.Search/searchServices/indexes/read`, but don't say it covers the data-plane GET | Learn: search-security-rbac (roles table) |
| 2 | Embeddings through the token proxy | **Yes, unchanged.** `azure:EmbeddingProvider` sends its `accessToken` argument as an **`api-key` header** (`auth: {apiKey}` / `{"api-key": …}`), the same Foundry account and audience as the chat model. The agent identity already has Cognitive Services OpenAI User there | `embedding_provider.bal:84,184,237` |
| 3 | Free tier | **No Free search service exists in `integration-rnd-001`** (Resource Graph: 2 Standard services, both in another team's resource group in Central US), so the one-per-subscription Free slot is available. Free: 50 MB, 3 indexes, vector fields (up to 4096 dimensions), **RBAC supported**, semantic ranker free plan. Our data (6 short documents, about 30 chunks × 1536 dimensions, about 0.2 MB) fits easily. Risks: "might be deleted after extended periods of inactivity", and no SLA | Resource Graph query; Learn: search-limits-quotas-capacity, search-security-enable-roles, search-sku-tier |
| – | Index schema `ingest()` needs | key `id` (string), `content` (string), a vector field (`dimensions` + `vectorSearchProfile`), optional `type`; **only metadata keys that exist as fields are stored**, so add `fileName` for citations. Keys are random UUIDs, so re-ingesting duplicates chunks unless they're deleted first | `azure_ai_search_knowledgebase.bal:743-812, 819-860` |

## Auth options for `indexesGet` and the recommendation

| Option | What the deployed agent gets | Verdict |
| --- | --- | --- |
| (a) Entra through a token proxy + **Search Service Contributor** | object management **and the ability to list admin keys** | works, but over-privileged |
| (a′) Entra + a **custom role** (`indexes/read` + `indexes/documents/read`) | least privilege, if the action covers the data-plane GET (undocumented) | needs creating a role definition in the shared subscription plus a test |
| (b) Upstream: let `AiSearchKnowledgeBase` take the schema (key, content and vector field names) and skip `indexesGet` | Search Index Data Reader only | the right fix, but not available now. **Draft the issue** |
| (c) Admin key in the agent | full data-plane access via a secret | goes against "no admin key in the deployed agent" |
| **(d) Token proxy serves the index definition** | **Search Index Data Reader only** | **recommended for now** |

**Recommendation: (d) now and (b) upstream.**
- **Search calls get the same treatment as model calls.** The agent talks to a second local hop on `127.0.0.1:8090` (audience
  `https://search.azure.com`). It swaps `api-key` for the agent identity's bearer token and forwards to the search service.
- **The one `GET /indexes('hr-policies')` call at startup is answered from `hr_agent/kb/hr-policies-index.json`**, the
  exact definition the ingestion program creates and that ships in the image. Everything else (`docs/search`) is
  forwarded, so the agent identity needs only **Search Index Data Reader**.
- **Trade-off:** it's a workaround tied to `AiSearchKnowledgeBase`'s startup behaviour, and the bundled definition must
  match the live index. The ingestion program writes the file, and the agent logs a warning if retrieval fails on a
  schema mismatch. It goes away once (b) lands.
- **Embeddings** go through the existing hop on `127.0.0.1:8089`, unchanged.

**Locally** (ingestion program and `bal run`), both hops use **your `az login` token** (`az account get-access-token`,
the equivalent of `AzureCliCredential` in Microsoft's hosted samples) instead of the managed-identity endpoint. The
agent's chat model keeps using `AZURE_OPENAI_KEY` locally, as now.

## Resources

| # | Resource | Name | Settings |
| --- | --- | --- | --- |
| 1 | Azure AI Search | `srch-dasuns-demo` | **Free**, East US, `authOptions: aadOrApiKey` + `http401WithBearerChallenge` (bearer tokens accepted; keys never used by our code) |
| 2 | Embedding deployment on `foundry-dasuns-demo` | `text-embedding-3-small` | model `text-embedding-3-small` v1, GlobalStandard, **capacity 10 (10K TPM)** |
| 3 | Index (created by the ingestion program) | `hr-policies` | `id` (key), `content` (searchable), `fileName` (filterable, retrievable), `type`, `contentVector` (1536, HNSW profile) |

If Free can't be created in East US, the fallback is **Basic ($73.73/month)**, and I'll ask before using it.

## Role assignments (each one asked for before it runs)

| # | Who | Role | Scope | Why | Phase |
| --- | --- | --- | --- | --- | --- |
| R1 | you | Search Service Contributor (`7ca78c08-…`) | `srch-dasuns-demo` | the ingestion program creates the index | 2 |
| R2 | you | Search Index Data Contributor (`8ebe5a00-…`) | `srch-dasuns-demo` | upload chunks, test `retrieve` locally | 2 |
| R3 | agent identity `f57f194f-4573-4207-913f-72365879981b` (ServicePrincipal) | Search Index Data Reader (`1407120a-…`) | `srch-dasuns-demo` | the deployed agent queries the index | 4 |

No new role is needed for embeddings: you have Foundry User on the resource group, and the agent identity has
Cognitive Services OpenAI User on `foundry-dasuns-demo`. The Free service has no managed identity, and none is needed
(no indexers).

## Cost (Azure Retail Prices API, East US, 2026-11-11)

| Item | Estimate |
| --- | --- |
| Search Free | **$0** |
| text-embedding-3-small (Global, $0.02 / 1M tokens) | < $0.01 (about 5K tokens to ingest, about 20 per query) |
| **Total** | **about $0 / month** (Basic fallback: $73.73 / month) |

## Commands

```sh
RG=rg-foundry-dasuns; SEARCH=srch-dasuns-demo; FOUNDRY=foundry-dasuns-demo

# Read-only name check
az rest --method POST --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.Search/checkNameAvailability?api-version=2025-05-01" \
  --body "{\"name\":\"$SEARCH\",\"type\":\"searchServices\"}"

# 1. Search service (Free)
az search service create -g $RG -n $SEARCH -l eastus --sku free \
  --auth-options aadOrApiKey --aad-auth-failure-mode http401WithBearerChallenge --tags RequestedBy=dasuns@wso2.com

# 2. Embedding deployment, 10K TPM
az cognitiveservices account deployment create -g $RG -n $FOUNDRY --deployment-name text-embedding-3-small \
  --model-name text-embedding-3-small --model-version 1 --model-format OpenAI --sku GlobalStandard --capacity 10

# R1-R3 (each after a separate OK)
SEARCH_ID=$(az search service show -g $RG -n $SEARCH --query id -o tsv); ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id $ME --assignee-principal-type User --role "Search Service Contributor" --scope $SEARCH_ID     # R1
az role assignment create --assignee-object-id $ME --assignee-principal-type User --role "Search Index Data Contributor" --scope $SEARCH_ID  # R2
az role assignment create --assignee-object-id f57f194f-4573-4207-913f-72365879981b --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Reader" --scope $SEARCH_ID                                                                                       # R3

# 5-6. Ingest (local program in ingest/, uses your az login; no keys)
cd ingest && AZURE_SEARCH_ENDPOINT=https://$SEARCH.search.windows.net bal run
```

## Code layout (Phases 2–3)

- `hr_agent/policies/*.md`: 6 policies (leave, remote work, expenses, code of conduct, parental leave, travel),
  consistent with `data.bal`.
- `ingest/`: a separate Ballerina package that creates the index (`search:SearchIndex`), writes
  `hr_agent/kb/hr-policies-index.json`, loads the markdown files with `ai:TextDataLoader`, and calls `hrKb.ingest()`.
  It deletes existing chunks per `fileName` first, so re-runs don't duplicate.
- `hr_agent/kb.bal`: `azure:EmbeddingProvider` (via the 8089 hop) + `azure:AiSearchKnowledgeBase` (via the 8090 hop,
  index name `hr-policies`).
- `searchHrPolicies(question)`: `hrKb.retrieve(question, 5)` returns content + `fileName`. The mock policies are removed
  from `data.bal`, and the instructions ask the agent to name the source policy.
- New environment variables: `AZURE_SEARCH_ENDPOINT`, `AZURE_SEARCH_INDEX` (`hr-policies`),
  `EMBEDDING_DEPLOYMENT_NAME` (`text-embedding-3-small`). No secrets.

## Upstream issues found (to draft, not file)

1. `AiSearchKnowledgeBase.init` needs admin-level rights (`indexesGet`) even for retrieve-only use, so a query key or
   Search Index Data Reader can't construct it. Proposal: accept the schema (key, content and vector field names), or
   skip the GET when they're given.
2. API keys only: no Entra / token-provider auth (same as `docs/upstream-proposal-ai-azure-entra-auth.md`).
3. `EmbeddingProvider`'s `accessToken` parameter is sent as an `api-key` header, so the name suggests a bearer token
   that isn't supported.
4. Chunk keys are random UUIDs, so `ingest()` isn't idempotent. Re-ingesting a document duplicates its chunks.

## Cleanup

```sh
az search service delete -g rg-foundry-dasuns -n srch-dasuns-demo --yes      # also removes R1-R3 (scoped to it)
az cognitiveservices account deployment delete -g rg-foundry-dasuns -n foundry-dasuns-demo --deployment-name text-embedding-3-small
az role assignment list -g rg-foundry-dasuns --include-inherited -o table      # check nothing is left over
```
