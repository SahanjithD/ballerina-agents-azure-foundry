# Experiments for the Entra auth design

Small local proofs for the facts in [`../entra-auth-ai-azure.md`](../entra-auth-ai-azure.md) §3. They use mock
HTTP endpoints on localhost only (no Azure, all credentials are dummies). Ballerina 2201.14.0.

| Dir | Proves | Run | Result |
|---|---|---|---|
| `headers/` | A7: generated `azure.openai.chat` 4.0.0 — a static `BearerTokenConfig` overrides a per-call `Authorization` header; `ApiKeysConfig` always sends `api-key` (even empty) | `cd headers && bal run` | `expected-output.txt` |
| `authexp/` | H4–H9: `http:Client` OAuth2 client-credentials — eager token fetch at init, body/header shape, `optionalParams` frozen, single-flight refresh, no 401 re-fetch | `cd authexp && bal run` | `expected-output.txt` |
| `panictest/` | H4: unreachable token endpoint at `http:Client` init panics; `http:Client\|error` does not catch it | `cd panictest && bal run` | exits with `Failed to call the token endpoint` from `ClientOAuth2Provider:init` |
| `dtcheck/` | A8: a pure-Ballerina class can't implement a dependently typed `generate` by delegation | `bal build dtcheck/main.bal` | compile error: `a function with a non-'external' function body cannot be a dependently-typed function` |
| `probe.sh` | Q1/Q2 (§3.6 "Observed", §3.8): which token audience each Azure OpenAI / project route accepts, and whether a stray `api-key` header next to a Bearer token is tolerated. **Calls Azure (read-only, minimal prompts); needs `az login` and a data-plane role.** Prints only HTTP status and error codes, never tokens. | `RES=<resource> PROJECT=<project> DEP=<deployment> ./probe.sh` | see §3.6 |
