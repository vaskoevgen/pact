#!/usr/bin/env bash
# monitor-pact.sh — watch a pact daemon, auto-handle pauses, tail live logs
#
# Usage:
#   bash monitor-pact.sh <project-dir> [interval-seconds]
#
# Examples:
#   bash monitor-pact.sh .                     # project in current dir, 30s poll
#   bash monitor-pact.sh ../my-project 15      # 15s poll
#   bash monitor-pact.sh /abs/path/to/project
#
# Env vars:
#   STUCK_TIMEOUT   seconds of no audit progress before restart (default 600)
#
# Pact binary discovery (in order):
#   1. .venv/bin/pact next to this script  (pact repo checkout)
#   2. `pact` on PATH
#
# API key discovery (in order):
#   1. ANTHROPIC_API_KEY already in environment
#   2. .env in project dir, then up to 4 parent dirs, then ~/

# NOTE: no set -e / set -o pipefail — grep returns 1 on no-match and
# would silently kill the script at unexpected points. All errors are
# handled explicitly.

# ── resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${1:-.}"
PROJECT="$(cd "$PROJECT" && pwd)"
INTERVAL="${2:-30}"

# find pact binary
if   [[ -x "$SCRIPT_DIR/.venv/bin/pact" ]]; then PACT="$SCRIPT_DIR/.venv/bin/pact"
elif command -v pact &>/dev/null;            then PACT="$(command -v pact)"
else
    echo "ERROR: pact not found. Activate the venv or put pact on PATH." >&2
    exit 1
fi

# ── load API key ──────────────────────────────────────────────────────────────
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    dir="$PROJECT"
    for _ in 1 2 3 4; do
        if [[ -f "$dir/.env" ]]; then
            # shellcheck source=/dev/null
            source "$dir/.env"
            echo "Loaded API key from $dir/.env"
            break
        fi
        dir="$(dirname "$dir")"
    done
    if [[ -z "${ANTHROPIC_API_KEY:-}" && -f "$HOME/.env" ]]; then
        source "$HOME/.env"
    fi
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "WARNING: ANTHROPIC_API_KEY not set — daemon may fail on API calls" >&2
fi

# ── helpers ───────────────────────────────────────────────────────────────────
ts()  { date '+%H:%M:%S'; }
sep() { printf '%0.s─' {1..64}; echo; }

# safe grep — never returns non-zero (avoids set -e / pipefail surprises)
sgrep() { grep "$@" || true; }

print_status() {
    local s="$1"
    local phase cost daemon state health
    phase=$(  echo "$s" | sgrep -oE 'Phase: [a-z_]+'  | head -1 | awk '{print $2}')
    cost=$(   echo "$s" | sgrep -oE '\$[0-9]+\.[0-9]+' | head -1)
    daemon=$( echo "$s" | sgrep -oE 'Daemon: [a-z]+'  | head -1 | awk '{print $2}')
    state=$(  echo "$s" | sgrep -oE '\] [a-z]+'       | head -1 | tr -d '[] ')
    health=$( echo "$s" | sgrep -oE 'Health: [A-Z]+'  | head -1 | awk '{print $2}')
    phase="${phase:-?}"
    cost="${cost:-\$?.??}"
    daemon="${daemon:-?}"
    state="${state:-?}"
    printf '[%s]  daemon=%-8s  state=%-8s  phase=%-12s  cost=%-8s  %s\n' \
        "$(ts)" "$daemon" "$state" "$phase" "$cost" "$health"
}

print_log() {
    local n="${1:-8}"
    local out
    out=$("$PACT" log "$PROJECT" 2>&1 | tail -"$n")
    if [[ -n "$out" ]]; then
        echo "  ┌─ pact log (last $n) ────────────────────────────────"
        echo "$out" | sed 's/^/  │ /'
        echo "  └──────────────────────────────────────────────────────"
    fi
}

print_components() {
    local out
    out=$("$PACT" components "$PROJECT" 2>&1)
    if [[ -n "$out" ]]; then
        echo "  ┌─ components ────────────────────────────────────────"
        echo "$out" | sed 's/^/  │ /'
        echo "  └────────────────────────────────────────────────────"
    fi
}

# returns the ISO timestamp of the most recent audit log entry, or ""
last_audit_ts() {
    local log_out ts
    log_out=$("$PACT" log "$PROJECT" 2>/dev/null) || true
    ts=$(echo "$log_out" | sgrep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -1)
    echo "$ts"
}

# convert ISO timestamp to epoch seconds (macOS + Linux)
iso_to_epoch() {
    local iso="$1"
    date -j -f '%Y-%m-%dT%H:%M:%S' "$iso" '+%s' 2>/dev/null \
        || date -d "$iso" '+%s' 2>/dev/null \
        || echo 0
}

# ── main loop ─────────────────────────────────────────────────────────────────
sep
echo "  pact monitor"
printf "  project:  %s\n" "$PROJECT"
printf "  pact:     %s\n" "$PACT"
printf "  interval: %ss   (Ctrl+C to stop)\n" "$INTERVAL"
sep

LAST_PHASE=""
LAST_AUDIT_TS=""
STUCK_TIMEOUT="${STUCK_TIMEOUT:-600}"

while true; do
    STATUS=$("$PACT" status "$PROJECT" 2>&1) || STATUS="ERROR: pact status failed"
    PHASE=$(echo "$STATUS" | sgrep -oE 'Phase: [a-z_]+' | head -1 | awk '{print $2}')

    print_status "$STATUS"

    # ── always print log; components on implement/integrate ───
    print_log 6
    if [[ "$PHASE" == "implement" || "$PHASE" == "integrate" ]]; then
        print_components
    fi

    LAST_PHASE="$PHASE"

    # ── auto-handle pauses ────────────────────────────────────
    if echo "$STATUS" | sgrep -q "Interview questions pending"; then
        echo "[$(ts)] → INTERVIEW PAUSE — running: pact approve"
        "$PACT" approve "$PROJECT" 2>&1 | sgrep -E 'Q:|Daemon|approved' | head -6
        LAST_AUDIT_TS=""
    fi

    if echo "$STATUS" | sgrep -qiE "health.*check|dysmemic|DEGRADED|Reason:.*health|paused.*health"; then
        echo "[$(ts)] → HEALTH GATE — running: pact resume"
        "$PACT" resume "$PROJECT" 2>&1
        LAST_AUDIT_TS=""
    fi

    # ── silent-hang detection ─────────────────────────────────
    if echo "$STATUS" | sgrep -q "Daemon: running" && echo "$STATUS" | sgrep -q "active"; then
        CURRENT_AUDIT_TS=$(last_audit_ts)
        if [[ -n "$CURRENT_AUDIT_TS" ]]; then
            if [[ "$CURRENT_AUDIT_TS" == "$LAST_AUDIT_TS" && -n "$LAST_AUDIT_TS" ]]; then
                LAST_EPOCH=$(iso_to_epoch "$LAST_AUDIT_TS")
                NOW_EPOCH=$(date '+%s')
                SILENT_SECS=$(( NOW_EPOCH - LAST_EPOCH ))
                if (( SILENT_SECS >= STUCK_TIMEOUT )); then
                    echo "[$(ts)] ⚠  SILENT HANG — no progress for ${SILENT_SECS}s (limit=${STUCK_TIMEOUT}s)"
                    DPID=$(echo "$STATUS" | sgrep -oE 'PID [0-9]+' | awk '{print $2}')
                    if [[ -n "$DPID" ]]; then
                        echo "[$(ts)] → killing PID $DPID and restarting..."
                        kill "$DPID" 2>/dev/null || true
                        sleep 2
                    fi
                    "$PACT" daemon "$PROJECT" &
                    sleep 4
                    "$PACT" resume "$PROJECT" 2>/dev/null || true
                    echo "[$(ts)] daemon restarted after hang"
                    LAST_AUDIT_TS=""
                else
                    echo "[$(ts)] ℹ  no new audit entries for ${SILENT_SECS}s (hang threshold=${STUCK_TIMEOUT}s)"
                fi
            else
                LAST_AUDIT_TS="$CURRENT_AUDIT_TS"
            fi
        fi
    fi

    # ── restart daemon if dead ────────────────────────────────
    if echo "$STATUS" | sgrep -qiE "stopped|no daemon|not running|ERROR:"; then
        echo "[$(ts)] ⚠  daemon dead — restarting..."
        "$PACT" daemon "$PROJECT" &
        sleep 4
        "$PACT" resume "$PROJECT" 2>/dev/null || true
        echo "[$(ts)] daemon restarted"
        LAST_AUDIT_TS=""
    fi

    # ── terminal states ───────────────────────────────────────
    if echo "$STATUS" | sgrep -qE 'complete|certified'; then
        sep
        echo "[$(ts)] ✅  BUILD COMPLETE"
        sep
        print_log 15
        print_components
        exit 0
    fi

    if echo "$STATUS" | sgrep -q "failed"; then
        sep
        echo "[$(ts)] ❌  BUILD FAILED"
        sep
        print_log 20
        exit 1
    fi

    sleep "$INTERVAL"
done
