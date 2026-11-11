# Foundry IQ knowledge base for the HR agent: plan and cost

Status: **plan only, nothing created yet.** Every step that costs money or changes permissions waits for an explicit OK.
Scope: subscription `integration-rnd-001`, resource group `rg-foundry-dasuns`, region **East US**. Every new resource
is tagged `RequestedBy=dasuns@wso2.com`.

## What Phase 0 found

| Question | Answer | Evidence |
| --- | --- | --- |
| `ai:KnowledgeBase` (ballerina/ai 1.16.1) | `ingest(Chunk[]\|Document[]\|Document) returns Error?`, `retrieve(string query, int maxLimit, MetadataFilters? filters = ()) returns QueryMatch[]\|Error`, `deleteByFilter(MetadataFilters) returns Error?`. `QueryMatch` = `{Chunk chunk; float similarityScore}`; `Chunk` = `{string 'type; Metadata metadata?; anydata content}` | `modules/ai/rag.bal`, `rag-types.bal` in the bala cache |
| Bedrock MANAGED design to mirror | Attach-or-create. `ingest()` uses a direct-ingestion source and **waits until each document reaches a final state**, then reports failures (it doesn't return on the 202). An explicit chunker is rejected because the service re-chunks. `retrieve()` searches every source; `maxLimit = -1` means no limit. `deleteByFilter()` is reconstructed (pinned per-document probes) and names any sources it can't delete from | `knowledgebase_managed.bal` (branch `bedrock-vector-kb-implementation`) |
| Existing Azure support in `ballerinax/ai.azure` 1.5.1 | `AiSearchKnowledgeBase` is an **index-level vector KB**: client-side chunking and embedding, `search` with `vectorQueries`, **API key only**, api-version `2025-09-01`. It has **no knowledge bases or agentic retrieval** | `azure_ai_search_knowledgebase.bal` |
| Retrieve API | `POST {search}/knowledgebases('{kb}')/retrieve?api-version=2026-10-01` (newest **stable**; also `2026-11-01-preview`). Body: `messages` or `intents`, `retrievalReasoningEffort {kind: minimal\|low\|medium}`, `outputMode extractiveData\|answerSynthesis`, `maxOutputDocuments`, `maxRuntimeInSeconds`, `includeActivity`, `knowledgeSourceParams[]`. Response: `response[].content[].text` (grounding JSON, or the answer), `references[]` (`type`, `id`, `activitySource`, `rerankerScore`, `blobUrl`/`docKey`, `citationUrl`, `sourceData`), `activity[]` (per step: `elapsedMs`, tokens) | azure-search-documents 12.1.0 (`knowledgebases/_operations.py`, `models/_models.py`, `_enums.py`, default api-version `2026-10-01`); azure-rest-api-specs `stable/2026-10-01/examples/KnowledgeBaseRetrieve*.json`. Learn still names `2026-04-01` as GA and is behind the specs |
| Minimal effort | "At minimal effort, this step is skipped and queries are issued directly to knowledge sources", so **no LLM call**. Answer synthesis needs low/medium | Learn: agentic-retrieval-overview |
| Chat model for query planning | **Optional** for a blob source. **gpt-5.5 is a supported KB model** (listed for 2026-08-01-preview; the 2026-10-01 stable examples accept a model + `low`; confirm with gpt-5.5 in Phase 2) | Learn: create-knowledge-base model table |
| Embedding model for a blob source | `ingestionParameters.embeddingModel` is **optional** in the 2026-10-01 spec; examples use text-embedding-3-large. Without it there's no vector search, only keyword + semantic | `models-knowledgebase.tsp` (`embeddingModel?`, `chatCompletionModel?`) |
| Generated objects | The blob knowledge source creates a data source, skillset, index and indexer (`<ks>-datasource/-skillset/-index/-indexer`), and deletes them when the knowledge source is deleted | Learn: agentic-knowledge-source-how-to-blob |
| Search tier | Agentic retrieval runs on all tiers (Free billing plan), but **Free has no managed identity for outbound access**, and managed-identity model access needs **Basic+**. East US supports agentic retrieval | Learn: search-sku-tier, agentic-retrieval-how-to-create-knowledge-base, search-region-support (2026-10-23) |
| Retrieve auth | `Search Index Data Reader`, token audience `https://search.azure.com`. The service must accept bearer tokens (`authOptions: aadOrApiKey` or RBAC-only) | Learn: agentic-retrieval-how-to-retrieve, search-security-enable-roles |
| Your Owner condition | You can assign any role **except** Owner, User Access Administrator and RBAC Administrator, so every role below is allowed | Role assignment condition on `rg-foundry-dasuns` |

## Resources to create

| # | Resource | Name | Settings |
| --- | --- | --- | --- |
| 1 | Azure AI Search | `srch-dasuns-demo` | **Basic**, 1 replica, 1 partition, system-assigned identity, `authOptions: aadOrApiKey` (bearer tokens accepted; keys never used), semantic ranker **free** plan, agentic retrieval **free** plan (default: 50M tokens/month; over that, requests fail instead of being billed) |
| 2 | Storage account | `stdasunsdemokb` | StorageV2, Standard_LRS, Hot, no public blob access, TLS 1.2, **shared-key access disabled** (Entra only) |
| 3 | Blob container | `hr-policies` | private |
| 4 | Embedding deployment on `foundry-dasuns-demo` | `text-embedding-3-small` | model `text-embedding-3-small` v1, **GlobalStandard, capacity 10 (10K TPM)** |
| 5 | Knowledge source (data plane) | `hr-policies-ks` | `azureBlob`, container `hr-policies`, `connectionString: ResourceId=<storage id>` (Search's identity), `embeddingModel` = item 4 (keyless), `contentExtractionMode: minimal`, image verbalization off, no chat model |
| 6 | Knowledge base (data plane) | `hr-policies-kb` | sources `[hr-policies-ks]`, `models: [gpt-5.5 on foundry-dasuns-demo]` (keyless), default `retrievalReasoningEffort: minimal`, `outputMode: extractiveData`. `low` is tried per request in Phase 2 |

Names 1 and 2 are global. Availability is checked (read-only) before creating.

## Role assignments (each one asked for separately before it runs)

| # | Who | Role (ID) | Scope | Why |
| --- | --- | --- | --- | --- |
| R1 | `srch-dasuns-demo` system identity | Storage Blob Data Reader (`2a2b9908-…`) | storage account `stdasunsdemokb` | indexer reads the policy documents |
| R2 | `srch-dasuns-demo` system identity | Cognitive Services User (`a97b65f3-…`) | Foundry resource `foundry-dasuns-demo` | embeddings during indexing and queries; gpt-5.5 when effort is low |
| R3 | you (dasuns) | Storage Blob Data Contributor (`ba92f5b4-…`) | storage account `stdasunsdemokb` | upload documents with `--auth-mode login` (shared key is off) |
| R4 | you (dasuns) | Search Service Contributor (`7ca78c08-…`) | search service `srch-dasuns-demo` | create the knowledge source and knowledge base keyless |
| R5 | you (dasuns) | Search Index Data Contributor (`8ebe5a00-…`) | search service `srch-dasuns-demo` | run `retrieve` locally (includes read); inspect the index |
| R6 | agent identity `f57f194f-4573-4207-913f-72365879981b` (ServicePrincipal) | Search Index Data Reader (`1407120a-…`) | search service `srch-dasuns-demo` | the deployed agent calls `retrieve` (**Phase 4**) |

## Estimated cost (East US, Azure Retail Prices API, 2026-11-11)

| Item | Price | Estimate |
| --- | --- | --- |
| Search **Basic** | $0.101 / hour | **$73.73 / month** (about $2.42 / day; billed hourly while it exists) |
| Agentic retrieval tokens | $0.022 / 1M tokens (all effort levels); free plan includes 50M / month | $0 on the free plan |
| Semantic ranker | free plan: 1,000 requests / month | $0 |
| text-embedding-3-small (Global) | $0.02 / 1M tokens | under $0.01 (a few thousand tokens to index; a few per query) |
| gpt-5.5 query planning (only at `low`) | same deployment and rate as the agent's own calls | a few hundred tokens per retrieve |
| Storage (a few KB, LRS Hot) | | under $0.05 / month |
| **Total** | | **about $74 / month, or about $2.45 / day.** Delete the Search service when the demo is over |

**Alternative, not recommended: the Free Search tier ($0).** It has no managed identity for outbound access, so the
knowledge source would need a storage account key in its connection string and an Azure OpenAI API key for embeddings,
and shared-key access would have to stay on. It allows only one Free service per subscription (a colleague may already
have it), and has 50 MB / 3 indexes.

## Commands

All `az` commands use `-g rg-foundry-dasuns`. Data-plane calls use `az rest --resource https://search.azure.com`
(Entra token; nothing is printed).

```sh
RG=rg-foundry-dasuns; LOC=eastus; TAGS="RequestedBy=dasuns@wso2.com"
SEARCH=srch-dasuns-demo; ST=stdasunsdemokb; CONTAINER=hr-policies; FOUNDRY=foundry-dasuns-demo
API=2026-10-01; SEARCH_URL="https://${SEARCH}.search.windows.net"

# 0. Read-only name checks
az storage account check-name --name "$ST"
az rest --method POST --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.Search/checkNameAvailability?api-version=2025-05-01" \
  --body "{\"name\":\"$SEARCH\",\"type\":\"searchServices\"}"

# 1. Search service
az search service create -g $RG -n $SEARCH -l $LOC --sku basic --replica-count 1 --partition-count 1 \
  --identity-type SystemAssigned --auth-options aadOrApiKey --aad-auth-failure-mode http401WithBearerChallenge \
  --semantic-search free --tags $TAGS

# 2-3. Storage account and container (Entra only)
az storage account create -g $RG -n $ST -l $LOC --sku Standard_LRS --kind StorageV2 --access-tier Hot \
  --allow-blob-public-access false --min-tls-version TLS1_2 --allow-shared-key-access false --tags $TAGS
az storage container create --account-name $ST -n $CONTAINER --auth-mode login     # after R3

# 4. Embedding deployment, 10K TPM
az cognitiveservices account deployment create -g $RG -n $FOUNDRY --deployment-name text-embedding-3-small \
  --model-name text-embedding-3-small --model-version 1 --model-format OpenAI --sku GlobalStandard --capacity 10

# R1-R6 (each after a separate OK)
SEARCH_MI=$(az search service show -g $RG -n $SEARCH --query identity.principalId -o tsv)
ST_ID=$(az storage account show -g $RG -n $ST --query id -o tsv)
FOUNDRY_ID=$(az cognitiveservices account show -g $RG -n $FOUNDRY --query id -o tsv)
SEARCH_ID=$(az search service show -g $RG -n $SEARCH --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id $SEARCH_MI --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" --scope $ST_ID        # R1
az role assignment create --assignee-object-id $SEARCH_MI --assignee-principal-type ServicePrincipal --role "Cognitive Services User" --scope $FOUNDRY_ID     # R2
az role assignment create --assignee-object-id $ME --assignee-principal-type User --role "Storage Blob Data Contributor" --scope $ST_ID                       # R3
az role assignment create --assignee-object-id $ME --assignee-principal-type User --role "Search Service Contributor" --scope $SEARCH_ID                      # R4
az role assignment create --assignee-object-id $ME --assignee-principal-type User --role "Search Index Data Contributor" --scope $SEARCH_ID                   # R5
az role assignment create --assignee-object-id f57f194f-4573-4207-913f-72365879981b --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Reader" --scope $SEARCH_ID                                                                                                        # R6 (Phase 4)

# 7. Upload the policy documents
az storage blob upload-batch --account-name $ST -d $CONTAINER -s kb/policies --auth-mode login

# 8. Knowledge source and knowledge base (bodies in kb/; written in Phase 2)
az rest --method PUT --resource https://search.azure.com --url "$SEARCH_URL/knowledgesources('hr-policies-ks')?api-version=$API" --body @kb/knowledge-source.json
az rest --method PUT --resource https://search.azure.com --url "$SEARCH_URL/knowledgebases('hr-policies-kb')?api-version=$API" --body @kb/knowledge-base.json
az rest --method POST --resource https://search.azure.com --url "$SEARCH_URL/knowledgebases('hr-policies-kb')/retrieve?api-version=$API" --body @kb/retrieve-sample.json
```

## Cleanup (after the demo)

```sh
az rest --method DELETE --resource https://search.azure.com --url "$SEARCH_URL/knowledgebases('hr-policies-kb')?api-version=$API"
az rest --method DELETE --resource https://search.azure.com --url "$SEARCH_URL/knowledgesources('hr-policies-ks')?api-version=$API"   # also deletes the generated index, indexer, skillset, data source
az search service delete -g rg-foundry-dasuns -n srch-dasuns-demo --yes        # stops the $2.42/day; also removes R4, R5, R6 (scoped to it)
az storage account delete -g rg-foundry-dasuns -n stdasunsdemokb --yes         # also removes R1, R3
az cognitiveservices account deployment delete -g rg-foundry-dasuns -n foundry-dasuns-demo --deployment-name text-embedding-3-small
az role assignment delete --assignee <search identity principal ID> --role "Cognitive Services User" --scope <foundry id>   # R2 (scope outlives the search service)
```

Deleting a resource deletes role assignments scoped **to** it, but they can linger as "Identity not found" entries.
Check with `az role assignment list -g rg-foundry-dasuns --include-inherited -o table` afterwards.

## Open points to confirm in Phase 2

- gpt-5.5 as the KB model with api-version 2026-10-01 (Learn's table lists it for 2026-08-01-preview).
- Whether `contentExtractionMode: minimal` + an embedding model is enough for Markdown/PDF policies (no Content Understanding).
- How the indexer handles deleted blobs. This decides `deleteByFilter` (Bedrock MANAGED-style: report what can't be done
  rather than silently skipping).
