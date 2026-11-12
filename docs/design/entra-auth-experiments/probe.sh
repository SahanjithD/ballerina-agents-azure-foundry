#!/bin/bash
# Read-only probes for Q1 (scope per endpoint) and Q2 (empty api-key next to Bearer).
# Tokens live only in shell variables; output is the HTTP status plus the service's error code/message.
set -u
: "${RES:?set RES to the Foundry/AOAI resource name}" "${PROJECT:?set PROJECT}" "${DEP:?set DEP to a chat deployment}"
OAI=https://$RES.openai.azure.com
SVC=https://$RES.services.ai.azure.com
PROJ=$SVC/api/projects/$PROJECT

TOK_CS=$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)
TOK_AI=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
[ -n "$TOK_CS" ] && [ -n "$TOK_AI" ] || { echo "token fetch failed"; exit 1; }
echo "tokens acquired (values not shown)"

CHAT_BODY_V1="{\"model\":\"$DEP\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"max_completion_tokens\":32}"
CHAT_BODY_LEGACY='{"messages":[{"role":"user","content":"Say OK"}],"max_completion_tokens":32}'

# probe <label> <method> <url> <body|-> [extra curl header args...]
probe() {
  local label=$1 method=$2 url=$3 body=$4; shift 4
  local out code
  if [ "$body" = "-" ]; then
    out=$(curl -s -m 60 -X "$method" "$url" "$@" -w $'\n%{http_code}')
  else
    out=$(curl -s -m 60 -X "$method" "$url" -H "Content-Type: application/json" "$@" -d "$body" -w $'\n%{http_code}')
  fi
  code=${out##*$'\n'}
  local detail
  detail=$(printf '%s' "${out%$'\n'*}" | python3 -I -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("(non-JSON body)"); sys.exit()
e=d.get("error") if isinstance(d,dict) else None
if isinstance(e,dict):
    print("error:", e.get("code"), "-", str(e.get("message",""))[:110])
elif isinstance(d,dict) and "choices" in d:
    print("ok: model=%s finish=%s" % (d.get("model"), d["choices"][0].get("finish_reason") if d["choices"] else None))
elif isinstance(d,dict) and "data" in d:
    print("ok: %d items" % len(d["data"]))
elif isinstance(d,dict) and "value" in d:
    print("ok: %d items" % len(d["value"]))
else:
    print("keys:", list(d)[:6] if isinstance(d,dict) else type(d).__name__)
')
  printf '%-58s %s  %s\n' "$label" "$code" "$detail"
}

echo; echo "== Q1: which token audience each endpoint accepts"
for pair in "cognitiveservices:$TOK_CS" "ai.azure.com:$TOK_AI"; do
  aud=${pair%%:*}; tok=${pair#*:}
  H=(-H "Authorization: Bearer $tok")
  probe "[$aud] v1 chat  openai.azure.com/openai/v1"          POST "$OAI/openai/v1/chat/completions" "$CHAT_BODY_V1" "${H[@]}"
  probe "[$aud] v1 chat  services.ai.azure.com/openai/v1"     POST "$SVC/openai/v1/chat/completions" "$CHAT_BODY_V1" "${H[@]}"
  probe "[$aud] legacy chat openai.azure.com (2024-10-21)"     POST "$OAI/openai/deployments/$DEP/chat/completions?api-version=2024-10-21" "$CHAT_BODY_LEGACY" "${H[@]}"
  probe "[$aud] project: GET deployments (api-version=v1)"     GET  "$PROJ/deployments?api-version=v1" - "${H[@]}"
  probe "[$aud] project: v1 chat  /api/projects/<p>/openai/v1" POST "$PROJ/openai/v1/chat/completions" "$CHAT_BODY_V1" "${H[@]}"
done

echo; echo "== Q2: valid Bearer (cognitiveservices) plus an api-key header"
H=(-H "Authorization: Bearer $TOK_CS")
probe "v1 chat     + empty api-key"         POST "$OAI/openai/v1/chat/completions" "$CHAT_BODY_V1" "${H[@]}" -H "api-key;"
probe "legacy chat + empty api-key"         POST "$OAI/openai/deployments/$DEP/chat/completions?api-version=2024-10-21" "$CHAT_BODY_LEGACY" "${H[@]}" -H "api-key;"
probe "v1 chat     + placeholder api-key"   POST "$OAI/openai/v1/chat/completions" "$CHAT_BODY_V1" "${H[@]}" -H "api-key: placeholder-not-a-key"
probe "legacy chat + placeholder api-key"   POST "$OAI/openai/deployments/$DEP/chat/completions?api-version=2024-10-21" "$CHAT_BODY_LEGACY" "${H[@]}" -H "api-key: placeholder-not-a-key"
unset TOK_CS TOK_AI
