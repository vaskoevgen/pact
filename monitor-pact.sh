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
# Pact binary discovery (in order):
#   1. .venv/bin/pact next to this script  (pact repo checkout)
#   2. `pact` on PATH
#
# API key discovery (in order):
#   1. ANTHROPIC_API_KEY already in environment
#   2. .env in project dir, then up to 4 parent dirs, then ~/

set -euo pipefail

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
    [[ -z "${ANTHROPIC_API_KEY:-}" && -f "$HOME/.env" ]] && source "$HOME/.env"
fi

[[ -z "${ANTHROPIC_API_KEY:-}" ]] && \
    echo "WARNING: ANTHROPIC_API_KEY not set — daemon may fail on API calls" >&2

# ── helpers ───────────────────────────────────────────────────────────────────
ts()  { date '+%H:%M:%S'; }
sep() { printf '%0.s─' {1..64}; echo; }

print_status() {
    local s="$1"
    local phase cost daemon state health
    phase=$(  echo "$s" | grep -oE 'Phase: [a-z_]+'  | head -1 | awk '{print $2}' || echo '?')
    cost=$(   echo "$s" | grep -oE '\$[0-9]+\.[0-9]+' | head -1 || echo '$?.??')
    daemon=$( echo "$s" | grep -oE 'Daemon: [a-z]+'  | head -1 | awk '{print $2}' || echo '?')
    state=$(  echo "$s" | grep -oE '\] [a-z]+'       | head -1 | tr -d '[] ' || echo '?')
    health=$( echo "$s" | grep -oE 'Health: [A-Z]+'  | head -1 | awk '{print $2}' || echo '')
    printf '[%s]  daemon=%-8s  state=%-8s  phase=%-12s  cost=%-8s  %s\n' \
        "$(ts)" "$daemon" "$state" "$phase" "$cost" "$health"
}

print_log() {
    local n="${1:-8}"
    local out
    out=$("$PACT" log "$PROJECT" 2>&1 | tail -"$n") || return 0
    [[ -z "$out" ]] && return 0
    echo "  ┌─ pact log (last $n entries) ─────────────────────────"
    echo "$out" | sed 's/^/  │ /'
    echo "  └──────────────────────────────────────────────────────"
}

print_components() {
    local out
    out=$("$PACT" components "$PROJECT" 2>&1) || return 0
    [[ -z "$out" ]] && return 0
    echo "  ┌─ components ───────────────────────────────────────"
    echo "$out" | sed 's/^/  │ /'
    echo "  └────────────────────────────────────────────────────"
}

# ── main loop ─────────────────────────────────────────────────────────────────
sep
echo "  pact monitor"
printf "  project:  %s\n" "$PROJECT"
printf "  pact:     %s\n" "$PACT"
printf "  interval: %ss   (Ctrl+C to stop)\n" "$INTERVAL"
sep

LAST_PHASE=""
CHECK=0
STUCK_TIMEOUT="${STUCK_TIMEOUT:-600}"   # seconds of no audit progress = stuck (default 10 min)
LAST_AUDIT_TS=""

# extract the timestamp of the most recent audit log entry
last_audit_ts() {
    "$PACT" log "$PROJECT" 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' \
        | tail -1
}

while true; do
    STATUS=$("$PACT" status "$PROJECT" 2>&1) || STATUS="ERROR: pact status failed"
    PHASE=$(echo "$STATUS" | grep -oE 'Phase: [a-z_]+' | head -1 | awk '{print $2}' || echo '')

    print_status "$STATUS"
    CHECK=$(( CHECK + 1 ))

    # show log on phase change or every 5 polls
    if [[ "$PHASE" != "$LAST_PHASE" || $(( CHECK % 5 )) -eq 0 ]]; then
        print_log 6
        [[ "$PHASE" == "implement" || "$PHASE" == "integrate" ]] && print_components
        LAST_PHASE="$PHASE"
    fi

    # ── auto-handle pauses ────────────────────────────────────
    if echo "$STATUS" | grep -q "Interview questions pending"; then
        echo "[$(ts)] → INTERVIEW PAUSE — running: pact approve"
        "$PACT" approve "$PROJECT" 2>&1 | grep -E 'Q:|Daemon|approved' | head -6
        LAST_AUDIT_TS=""   # reset; approval triggers new activity
    fi

    if echo "$STATUS" | grep -qiE "health.*check|dysmemic|DEGRADED|Reason:.*health|paused.*health"; then
        echo "[$(ts)] → HEALTH GATE — running: pact resume"
        "$PACT" resume "$PROJECT" 2>&1
        LAST_AUDIT_TS=""
    fi

    # ── silent-hang detection ─────────────────────────────────
    # Daemon is alive and status=active but audit log hasn't moved in STUCK_TIMEOUT seconds.
    if echo "$STATUS" | grep -q "Daemon: running" && echo "$STATUS" | grep -q "active"; then
        CURRENT_AUDIT_TS=$(last_audit_ts)
        if [[ -n "$CURRENT_AUDIT_TS" ]]; then
            if [[ "$CURRENT_AUDIT_TS" == "$LAST_AUDIT_TS" ]]; then
                # compute seconds since last audit entry
                LAST_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$LAST_AUDIT_TS" '+%s' 2>/dev/null \
                          || date -d "$LAST_AUDIT_TS" '+%s' 2>/dev/null || echo 0)
                NOW_EPOCH=$(date '+%s')
                SILENT_SECS=$(( NOW_EPOCH - LAST_EPOCH ))
                if (( SILENT_SECS >= STUCK_TIMEOUT )); then
                    echo "[$(ts)] ⚠  SILENT HANG detected — no audit progress for ${SILENT_SECS}s (limit=${STUCK_TIMEOUT}s)"
                    echo "[$(ts)] → killing daemon PID and restarting..."
                    DPID=$(echo "$STATUS" | grep -oE 'PID [0-9]+' | awk '{print $2}')
                    [[ -n "$DPID" ]] && kill "$DPID" 2>/dev/null && sleep 2
                    "$PACT" daemon "$PROJECT" &
                    sleep 4
                    "$PACT" resume "$PROJECT" 2>/dev/null || true
                    echo "[$(ts)] daemon restarted after hang"
                    LAST_AUDIT_TS=""
                fi
            else
                LAST_AUDIT_TS="$CURRENT_AUDIT_TS"
            fi
        fi
    fi

    # ── restart daemon if dead ────────────────────────────────
    if echo "$STATUS" | grep -qiE "stopped|no daemon|not running|ERROR:"; then
        echo "[$(ts)] ⚠  daemon dead — restarting..."
        "$PACT" daemon "$PROJECT" &
        sleep 4
        "$PACT" resume "$PROJECT" 2>/dev/null || true
        echo "[$(ts)] daemon restarted"
        LAST_AUDIT_TS=""
    fi

    # ── terminal states ───────────────────────────────────────
    if echo "$STATUS" | grep -qE 'complete|certified'; then
        sep
        echo "[$(ts)] ✅  BUILD COMPLETE"
        sep
        print_log 15
        print_components
        exit 0
    fi

    if echo "$STATUS" | grep -q "failed"; then
        sep
        echo "[$(ts)] ❌  BUILD FAILED"
        sep
        print_log 20
        exit 1
    fi

    sleep "$INTERVAL"
done
