#!/usr/bin/env bash
#
# ask.sh — query the local hardened llama-server (router mode) and print a
#          nicely formatted answer
# Usage: ./ask.sh ["model"] "your prompt"
#        echo "text" | ./ask.sh
#        ./ask.sh "your prompt"        ← model auto-selected from /v1/models
#
# Client for the hardened llama.cpp stack in ROUTER MODE with per-startup
# key rotation:
#   - API on 127.0.0.1:${UI_PORT} via the nginx UI container  → LLAMA_HOST
#   - key read from the tmpfs path compose mounts            → LLAMA_KEY_FILE
#     (overridable via the env vars below for testing)
# The browser needs no key (nginx injects it); CLI clients read the key
# file that keygen refreshed at this startup.
#
# Requires: curl, jq

set -euo pipefail

HOST="${LLAMA_HOST:-http://127.0.0.1:8081}"
MODEL="${1:-}"
PROMPT="${2:-}"

die() { printf '❌  %s\n' "$1" >&2; exit 1; }

for bin in curl jq; do
    command -v "$bin" >/dev/null || die "$bin is required but not installed"
done

# --- API key: tmpfs file (matches KEYS_DIR in compose) ---------------------
# Priority: LLAMA_KEY_FILE (explicit) → /run/llama-keys/api_key (stack default)
# → LLAMA_API_KEY_FILE/LLAMA_API_KEY (legacy/testing env fallbacks).
# The tmpfs vanishes on host reboot and keygen refills it on the next
# `docker compose up` — if this step fails, the stack is probably down or
# was rebooted without being brought back up.
KEY=""
if [[ -n "${LLAMA_KEY_FILE:-}" ]]; then
    [[ -r "$LLAMA_KEY_FILE" ]] || die "cannot read key file: $LLAMA_KEY_FILE"
    KEY="$(tr -d '[:space:]' < "$LLAMA_KEY_FILE")"
elif [[ -r /run/llama-keys/api_key ]]; then
    KEY="$(tr -d '[:space:]' < /run/llama-keys/api_key)"
elif [[ -n "${LLAMA_API_KEY_FILE:-}" && -r "${LLAMA_API_KEY_FILE}" ]]; then
    KEY="$(tr -d '[:space:]' < "$LLAMA_API_KEY_FILE")"
elif [[ -n "${LLAMA_API_KEY:-}" ]]; then
    KEY="$LLAMA_API_KEY"
fi
[[ -n "$KEY" ]] || die "no API key at /run/llama-keys/api_key — is the stack up? (docker compose up -d)"

# Bearer header in a private temp file — keeps the key out of argv/ps output.
umask 077
HDR="$(mktemp)"
trap 'rm -f "$HDR"' EXIT
printf 'Authorization: Bearer %s\n' "$KEY" > "$HDR"

# --- Model auto-discovery (router mode) -------------------------------------
# Single positional arg (or piped input) → treat it as the prompt and pick
# the first model the router advertises. With two args, arg 1 is the model
# name exactly as listed by /v1/models (GGUF filename without .gguf).
list_models() {
    curl -sS -f --connect-timeout 5 -H @"$HDR" "$HOST/v1/models" |
        jq -r '.data[].id'
}

discover_model() {
    local m
    m="$(list_models | head -n1)"
    [[ -n "$m" ]] || die "router advertises no models — is ${MODEL_DIR:-./models} populated?"
    printf '%s' "$m"
}

if [[ -z "$PROMPT" ]]; then
    # one positional arg: it is the prompt, model comes from the router
    PROMPT="$MODEL"
    MODEL="$(discover_model)"
fi

# Allow piping input instead of passing it as an argument
if [[ -z "$PROMPT" ]]; then
    PROMPT="$(cat)"
fi

if [[ -z "$PROMPT" ]]; then
    echo "Usage: $0 [model] \"prompt\"  — or pipe text in (model auto-selected)." >&2
    exit 1
fi

# --- Separator / header -----------------------------------------------------
divider() { printf '%*s\n' "$(tput cols)" '' | tr ' ' '─'; }

divider
printf "🤖  Host  : %s\n     Model : %s\n     Time  : %s\n" "$HOST" "$MODEL" "$(date '+%Y-%m-%d %H:%M:%S')"
divider
printf "\n"

# --- Stream the answer ------------------------------------------------------
# -N disables buffering so tokens appear as they arrive;
# --connect-timeout fails fast if the stack is down. A 500 from curl usually
# means the router is up but the requested model failed to load — check
# container logs. 401 = key rotated mid-session (rerun after `docker compose up`).
# 429 = proxy rate limiter; retry in a few seconds.
STATUS=0
curl -sS -f -N --connect-timeout 5 \
    -H @"$HDR" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$MODEL" --arg p "$PROMPT" '{
        model: $m,
        stream: true,
        messages: [
            {role: "system", content: "You are a helpful assistant. Answer clearly and concisely, using Markdown."},
            {role: "user",   content: $p}
        ]
    }')" \
    "$HOST/v1/chat/completions" |
while IFS= read -r line; do
    # Each SSE line looks like: data: {...json...}
    case "$line" in
        data:*)
            payload="${line#data: }"
            # Skip the final "[DONE]" marker
            [[ "$payload" == "[DONE]" ]] && continue
            # llama-server reports in-band errors as {"error": {...}}
            if jq -e 'has("error")' <<<"$payload" >/dev/null 2>&1; then
                jq -rj '"⚠️  server error: " + (.error.message // (.error|tostring))' <<<"$payload" >&2
                continue
            fi
            # Extract the delta text and print immediately (live streaming)
            jq -rj '.choices[0].delta.content // empty' <<<"$payload"
            ;;
    esac
done || STATUS=$?

# --- Footer -----------------------------------------------------------------
printf "\n\n"
divider
if [[ $STATUS -ne 0 ]]; then
    printf "❌  Request failed (curl exit %s) — is the stack up? 'docker compose ps'\n" "$STATUS"
else
    printf "✅  Done — %s\n" "$(date '+%H:%M:%S')"
fi
divider
exit "$STATUS"
