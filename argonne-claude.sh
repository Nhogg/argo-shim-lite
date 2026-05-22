#!/bin/bash

# Defaults
BACKEND=""
IDENTITY=""

# Parse args. Only --backend / --identity are consumed; anything else is ignored.
while [ $# -gt 0 ]; do
    case "$1" in
        --backend=*)
            BACKEND="${1#--backend=}"
            shift
            ;;
        --backend)
            BACKEND="$2"
            shift 2
            ;;
        --identity=*)
            IDENTITY="${1#--identity=}"
            shift
            ;;
        --identity)
            IDENTITY="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

CLAUDE_EXECUTABLE="${CLAUDE_EXECUTABLE:-claude}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

run_argo() {
    # Configuration
    REMOTE_HOST="homes.cels.anl.gov"
    TUNNEL_LOCAL_PORT=8082
    TUNNEL_REMOTE_HOST="apps.inside.anl.gov"
    TUNNEL_REMOTE_PORT=443
    PROXY_PORT=8083

    # SSH jump chain. On Aurora compute nodes ($PBS_JOBID set) the default
    # routes through a UAN; PBS records the submitting UAN in $PBS_O_HOST.
    # Users can override either the UAN or the whole chain.
    ARGO_AURORA_UAN="${ARGO_AURORA_UAN:-${PBS_O_HOST:-aurora-uan-0011}}"
    if [ -z "${ARGO_SSH_JUMP}" ] && [ -n "${PBS_JOBID}" ]; then
        ARGO_SSH_JUMP="${ARGO_AURORA_UAN},logins.cels.anl.gov"
    fi

    # SSH ControlMaster settings
    CONTROL_PATH="/tmp/ssh-argo-claude-$$"

    # Track PIDs for cleanup
    PROXY_PID=""

    cleanup() {
        echo -e "\n${YELLOW}Cleaning up...${NC}"

        if [ -n "${PROXY_PID}" ]; then
            kill ${PROXY_PID} 2>/dev/null
        fi

        # Close the SSH tunnel via control socket
        ssh -O exit -o ControlPath="${CONTROL_PATH}" ${REMOTE_HOST} 2>/dev/null || true

        echo -e "${GREEN}Done!${NC}"
        exit 0
    }

    trap cleanup SIGINT SIGTERM EXIT

    echo -e "${GREEN}Starting Argo Claude setup...${NC}"

    # Check if tunnel port is already in use
    if lsof -i :${TUNNEL_LOCAL_PORT} >/dev/null 2>&1; then
        echo -e "${RED}Port ${TUNNEL_LOCAL_PORT} is already in use.${NC}"
        echo -e "${YELLOW}Check for an existing SSH tunnel: lsof -i :${TUNNEL_LOCAL_PORT}${NC}"
        exit 1
    fi

    # Step 1: Start SSH tunnel (ssh -f backgrounds after MFA authentication completes)
    echo -e "${YELLOW}Starting SSH tunnel to ${TUNNEL_REMOTE_HOST}...${NC}"
    echo -e "${YELLOW}(You may need to complete MFA authentication)${NC}"

    SSH_JUMP_OPTS=()
    if [ -n "${ARGO_SSH_JUMP}" ]; then
        SSH_JUMP_OPTS=(-J "${ARGO_SSH_JUMP}")
        echo -e "${YELLOW}Using SSH jump chain: ${ARGO_SSH_JUMP}${NC}"
    fi

    ssh -f -N \
        "${SSH_JUMP_OPTS[@]}" \
        -o ControlMaster=yes \
        -o ControlPath="${CONTROL_PATH}" \
        -L ${TUNNEL_LOCAL_PORT}:${TUNNEL_REMOTE_HOST}:${TUNNEL_REMOTE_PORT} \
        ${REMOTE_HOST}

    if [ $? -ne 0 ]; then
        echo -e "${RED}SSH tunnel failed to start. Check your credentials and MFA.${NC}"
        exit 1
    fi

    echo -e "${GREEN}SSH tunnel established (port ${TUNNEL_LOCAL_PORT})!${NC}"

    # Step 2: Start local proxy
    echo -e "${YELLOW}Starting local proxy...${NC}"

    python3.12 "${SCRIPT_DIR}/claude-argo-proxy.py" &
    PROXY_PID=$!

    sleep 2

    if ! kill -0 ${PROXY_PID} 2>/dev/null; then
        echo -e "${RED}Local proxy failed to start. Is aiohttp installed? (pip install aiohttp)${NC}"
        exit 1
    fi

    echo -e "${GREEN}Local proxy running (port ${PROXY_PORT})!${NC}"

    # Step 3: Launch Claude Code
    # Identity precedence: --identity > $ARGO_USER > $USER
    ARGO_IDENTITY="${IDENTITY:-${ARGO_USER:-$USER}}"
    # Default to the inline renderer — friendlier over multi-hop SSH (e.g. compute
    # nodes), and preserves Claude's output in scrollback. User can override.
    echo -e "${GREEN}Launching Claude Code as ${ARGO_IDENTITY}...${NC}"
    ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}/argoapi/" \
        ANTHROPIC_AUTH_TOKEN="${ARGO_IDENTITY}" \
        CLAUDE_CODE_SKIP_ANTHROPIC_AUTH=1 \
        CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=${CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN:-1} \
        ${CLAUDE_EXECUTABLE}

    # The cleanup function will be called automatically by the trap on exit
}

run_asksage() {
    ASKSAGE_BASE_URL="${ASKSAGE_BASE_URL:-https://api.asksage.anl.gov/server/anthropic}"
    ASKSAGE_TOKEN_FILE="${ASKSAGE_TOKEN_FILE:-$HOME/.asksage/token}"

    echo -e "${GREEN}Starting AskSage Claude setup...${NC}"

    # Resolve API key. Precedence: --identity > $ASKSAGE_API_KEY > token file.
    if [ -n "${IDENTITY}" ]; then
        ASKSAGE_API_KEY="${IDENTITY}"
    elif [ -z "${ASKSAGE_API_KEY}" ] && [ -r "${ASKSAGE_TOKEN_FILE}" ]; then
        ASKSAGE_API_KEY="$(tr -d '[:space:]' < "${ASKSAGE_TOKEN_FILE}")"
    fi

    if [ -z "${ASKSAGE_API_KEY}" ]; then
        echo -e "${RED}No AskSage API key found.${NC}"
        echo -e "${YELLOW}Pass --identity=<api-key>, set \$ASKSAGE_API_KEY, or write the key to ${ASKSAGE_TOKEN_FILE}.${NC}"
        exit 1
    fi

    # The ANL AskSage server (api.asksage.anl.gov) does not include the
    # InCommon intermediate in its TLS chain, which makes Node's bundled CA
    # store (which has the USERTrust root but not the intermediate) fail to
    # verify. Add the intermediate explicitly so Claude Code's embedded Node
    # can complete the chain. NODE_EXTRA_CA_CERTS extends, not replaces, the
    # built-in roots, so this is safe for any tenant.
    ASKSAGE_EXTRA_CA="${SCRIPT_DIR}/certs/incommon-rsa-server-ca-2.pem"

    # Resolve which model Claude Code should use. Without this, Claude Code
    # picks its own default — currently the 1M-context Opus 4.7 variant, which
    # sends `anthropic-beta: context-1m-2025-08-07` and gets rejected by
    # AskSage. Ask the backend for its model list; AskSage returns them in
    # capability order (most-capable first), so data[0].id is a sensible
    # default. User can short-circuit the query via ASKSAGE_MODEL /
    # ASKSAGE_SMALL_FAST_MODEL.
    if [ -z "${ASKSAGE_MODEL}" ] || [ -z "${ASKSAGE_SMALL_FAST_MODEL}" ]; then
        echo -e "${YELLOW}Querying AskSage for available models...${NC}"
        MODELS_JSON="$(curl -sS --max-time 10 \
            --cacert "${ASKSAGE_EXTRA_CA}" \
            -H "Authorization: Bearer ${ASKSAGE_API_KEY}" \
            -H "anthropic-version: 2023-06-01" \
            "${ASKSAGE_BASE_URL}/v1/models" 2>/dev/null)"
        if [ -n "${MODELS_JSON}" ] && command -v python3 >/dev/null 2>&1; then
            PICKED="$(printf '%s' "${MODELS_JSON}" | python3 -c '
import json, sys
try:
    ids = [m.get("id","") for m in json.load(sys.stdin).get("data", []) if m.get("id")]
    main = ids[0] if ids else ""
    fast = next((i for i in ids if "haiku" in i.lower()), "")
    print(f"{main}|{fast}")
except Exception:
    print("|")
' 2>/dev/null)"
            DISCOVERED_MAIN="${PICKED%|*}"
            DISCOVERED_FAST="${PICKED#*|}"
            [ -z "${ASKSAGE_MODEL}" ] && ASKSAGE_MODEL="${DISCOVERED_MAIN}"
            [ -z "${ASKSAGE_SMALL_FAST_MODEL}" ] && ASKSAGE_SMALL_FAST_MODEL="${DISCOVERED_FAST}"
        fi
    fi

    MODEL_ENV=()
    if [ -n "${ASKSAGE_MODEL}" ]; then
        MODEL_ENV+=("ANTHROPIC_MODEL=${ASKSAGE_MODEL}")
        echo -e "${GREEN}Using main model: ${ASKSAGE_MODEL}${NC}"
    else
        echo -e "${YELLOW}Could not discover a main model; Claude Code will use its default (may fail against this backend).${NC}"
    fi
    if [ -n "${ASKSAGE_SMALL_FAST_MODEL}" ]; then
        MODEL_ENV+=("ANTHROPIC_SMALL_FAST_MODEL=${ASKSAGE_SMALL_FAST_MODEL}")
        echo -e "${GREEN}Using small/fast model: ${ASKSAGE_SMALL_FAST_MODEL}${NC}"
    fi

    # AskSage's upstream may or may not accept Claude Code's newer
    # `thinking: {type: "adaptive"}` mode (the Opus 4.7 default). The legacy
    # discriminated union only knows 'enabled' / 'disabled'. Probe with a
    # minimal request: if the backend rejects 'adaptive' specifically, set
    # CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING so Claude Code falls back to the
    # legacy mode. When AskSage eventually supports adaptive, the probe stops
    # finding the rejection and we leave Claude Code's default alone — no
    # code change needed. Skip the probe entirely if the user has already set
    # CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING themselves.
    if [ -z "${CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING+set}" ]; then
        echo -e "${YELLOW}Probing adaptive-thinking support...${NC}"
        PROBE_MODEL="${ASKSAGE_MODEL:-claude-haiku-4-5}"
        PROBE_RESP="$(curl -sS --max-time 10 \
            --cacert "${ASKSAGE_EXTRA_CA}" \
            -H "Authorization: Bearer ${ASKSAGE_API_KEY}" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -d "{\"model\":\"${PROBE_MODEL}\",\"max_tokens\":1,\"thinking\":{\"type\":\"adaptive\"},\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
            "${ASKSAGE_BASE_URL}/v1/messages" 2>/dev/null)"
        if printf '%s' "${PROBE_RESP}" | grep -q "Input tag 'adaptive'"; then
            export CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1
            echo -e "${YELLOW}Backend rejects adaptive thinking; disabling.${NC}"
        elif [ -z "${PROBE_RESP}" ]; then
            echo -e "${YELLOW}Adaptive-thinking probe got no response; leaving Claude Code defaults.${NC}"
        else
            echo -e "${GREEN}Adaptive thinking supported.${NC}"
        fi
    fi

    echo -e "${GREEN}Launching Claude Code against AskSage (${ASKSAGE_BASE_URL})...${NC}"
    env \
        ANTHROPIC_BASE_URL="${ASKSAGE_BASE_URL}" \
        ANTHROPIC_AUTH_TOKEN="${ASKSAGE_API_KEY}" \
        CLAUDE_CODE_SKIP_ANTHROPIC_AUTH=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-$ASKSAGE_EXTRA_CA}" \
        "${MODEL_ENV[@]}" \
        ${CLAUDE_EXECUTABLE}
}

if [ -z "${BACKEND}" ]; then
    echo -e "${RED}--backend is required.${NC}" >&2
    echo -e "${YELLOW}Use --backend=argo or --backend=asksage${NC}" >&2
    exit 1
fi

case "${BACKEND}" in
    argo)
        run_argo
        ;;
    asksage)
        run_asksage
        ;;
    *)
        echo -e "${RED}Unknown backend: ${BACKEND}${NC}" >&2
        echo -e "${YELLOW}Use --backend=argo or --backend=asksage${NC}" >&2
        exit 1
        ;;
esac
