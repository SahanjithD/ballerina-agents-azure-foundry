# Proposal: Microsoft Entra ID (token) auth for `ballerinax/ai.azure`

**Target:** https://github.com/ballerina-platform/ballerina-library/issues (label `module/ai.azure`)
**Status:** draft, not filed

## Problem

`azure:OpenAiModelProvider` (1.5.1) only supports API keys. The key is a constructor `string`, and every
code path sends it as an `api-key` header:

- `provider_utils.bal:524` and `responses_utils.bal:356`: `auth: {api\-key: apiKey}` for the generated
  chat/responses connectors
- `provider_utils.bal:385` and `responses_utils.bal:311`: `{"api-key": apiKey}` on the raw legacy clients

`ConnectionConfig` has no `auth` field and there is no token-provider hook. Azure OpenAI and Foundry accept
Entra tokens only as `Authorization: Bearer <token>`, and those tokens expire (typically within hours). So a
Ballerina agent can't use:

- a Foundry hosted agent's own identity (Entra Agent ID, exposed in the sandbox as a managed-identity
  endpoint: `IDENTITY_ENDPOINT`, `IDENTITY_HEADER`, `FOUNDRY_AGENT_INSTANCE_CLIENT_ID`)
- managed identities on App Service, Container Apps, AKS workload identity, and so on
- resources with key auth disabled (`disableLocalAuth: true`), which many organisations require

Calls made with a key also aren't attributed to the calling agent in Foundry's per-agent metrics, so the
agent's Monitor page shows 0 tokens.

Wrapping the provider isn't a workaround either. `ai:ModelProvider.generate` is dependently typed
(`returns td|Error`), so it can only be implemented as an `external` function. User code can't write a
delegating provider that swaps in a fresh token.

## Proposal

Add an auth option that can supply a fresh bearer token for each request:

```ballerina
public type TokenProvider isolated function () returns string|error;

public type EntraIdAuthConfig record {|
    # Called before each request; implementations cache and refresh tokens themselves.
    TokenProvider tokenProvider;
|};

public isolated function init(string serviceUrl,
        string|EntraIdAuthConfig auth,      // was: string apiKey
        string deploymentId, ...)
```

- `string`: today's behaviour (`api-key` header), so existing code keeps working.
- `EntraIdAuthConfig`: send `Authorization: Bearer <tokenProvider()>` on every request.

Optionally, the module could also ship ready-made token providers:

- `azure:managedIdentityTokenProvider(resource = "https://cognitiveservices.azure.com", clientId = ...)`
  following azure-identity's `ManagedIdentityCredential` source selection: App Service
  (`IDENTITY_ENDPOINT` + `IDENTITY_HEADER`, api-version `2019-08-01`), IMDS, and workload identity
  (`AZURE_FEDERATED_TOKEN_FILE`). Tokens are cached until 5 minutes before expiry.
- `azure:clientCredentialsTokenProvider(tenantId, clientId, clientSecret)`.

The same option applies to `EmbeddingProvider` and to the Azure AI Search knowledge base, which use the same
auth pattern.

## Workaround used in this repo

`hr_agent/identity.bal` runs a local HTTP hop on `127.0.0.1:8089`. The provider talks to it with a placeholder
API key; the hop removes `api-key`, adds `Authorization: Bearer <cached managed-identity token>` and forwards
the call to the real endpoint. It works, but it costs an extra in-process HTTP hop and a second listener, and
the proxy has to be kept in sync with whatever the provider sends. A token-provider option in the module would
remove all of that.
