#!/usr/bin/env bash
# monitor-pact.sh — watch a pact daemon, show NEW log entries each poll,
#                   auto-handle every pause type (interview, health gate, hang)
#
# Usage:
#   bash monitor-pact.sh <project-dir> [interval-seconds]
#
# Examples:
#   bash monitor-pact.sh .                      # current dir, 30s poll
#   bash monitor-pact.sh ../my-project 15       # 15s poll
#   bash monitor-pact.sh /abs/path/to/project
#
# Env vars:
#   STUCK_TIMEOUT   seconds with no new log entries before restart (default 600)
#
# NOTE: no set -e / set -o pipefail — grep exits 1 on no-match and would
# silently kill the script. All errors are handled explicitly instead.

# ── resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${1:-.}"
PROJECT="$(cd "$PROJECT" && pwd)"
INTERVAL="${2:-30}"
STUCK_TIMEOUT="${STUCK_TIMEOUT:-600}"

# find pact binary: prefer venv next to this script, then PATH
if   [[ -x "$SCRIPT_DIR/.venv/bin/pact" ]]; then PACT="$SCRIPT_DIR/.venv/bin/pact"
elif command -v pact &>/dev/null;            then PACT="$(command -v pact)"
else
    echo "ERROR: pact not found. Run 'make' in the pact repo or activate the venv." >&2
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

# grep for capturing output — never returns non-zero (avoids silent script death on pipefail)
sgrep() { grep "$@" || true; }
# grep for if-condition tests — exit code matters; since there's no set -e, plain grep is safe
cgrep() { grep "$@"; }

print_status() {
    local s="$1"
    local phase cost daemon state health
    phase=$(  echo "$s" | sgrep -oE 'Phase: [a-z_]+'  | head -1 | awk '{print $2}')
    cost=$(   echo "$s" | sgrep -oE '\$[0-9]+\.[0-9]+' | head -1)
    daemon=$( echo "$s" | sgrep -oE 'Daemon: [a-z]+'  | head -1 | awk '{print $2}')
    state=$(  echo "$s" | sgrep -oE '\] [a-z]+'       | head -1 | tr -d '[] ')
    health=$( echo "$s" | sgrep -oE 'Health: [A-Z]+'  | head -1 | awk '{print $2}')
    printf '[%s]  daemon=%-8s  state=%-8s  phase=%-12s  cost=%-8s  %s\n' \
        "$(ts)" \
        "${daemon:-?}" "${state:-?}" "${phase:-?}" "${cost:-\$?.??}" "${health:-}"
}

# Print only log entries we haven't seen yet.
# Tracks count across calls via SEEN_LOG_LINES variable.
SEEN_LOG_LINES=0
print_new_log_entries() {
    local all_log new_count new_lines delta
    all_log=$("$PACT" log "$PROJECT" 2>&1) || true

    # strip the trailing "N entries total" summary line
    new_count=$(echo "$all_log" | sgrep -c '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T')
    new_count="${new_count:-0}"

    delta=$(( new_count - SEEN_LOG_LINES ))
    if (( delta > 0 )); then
        new_lines=$(echo "$all_log" \
            | sgrep '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T' \
            | tail -"$delta")
        echo "  ┌─ pact log — $delta new $([ "$delta" -eq 1 ] && echo entry || echo entries) ──────────────────────────"
        echo "$new_lines" | sed 's/^/  │ /'
        echo "  └──────────────────────────────────────────────────────"
        SEEN_LOG_LINES="$new_count"
    fi
}

print_components() {
    local out
    out=$("$PACT" components "$PROJECT" 2>&1) || true
    if [[ -n "$out" ]]; then
        echo "  ┌─ components ────────────────────────────────────────"
        echo "$out" | sed 's/^/  │ /'
        echo "  └────────────────────────────────────────────────────"
    fi
}

# returns ISO timestamp of last audit entry, or ""
last_audit_ts() {
    local out
    out=$("$PACT" log "$PROJECT" 2>/dev/null) || true
    echo "$out" | sgrep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -1
}

iso_to_epoch() {
    date -j -f '%Y-%m-%dT%H:%M:%S' "$1" '+%s' 2>/dev/null \
        || date -d "$1" '+%s' 2>/dev/null \
        || echo 0
}

# ── main loop ─────────────────────────────────────────────────────────────────
sep
echo "  pact monitor"
printf "  project:  %s\n" "$PROJECT"
printf "  pact:     %s\n" "$PACT"
printf "  interval: %ss   hang-timeout: %ss   (Ctrl+C to stop)\n" "$INTERVAL" "$STUCK_TIMEOUT"
sep

# seed seen count so first poll only prints entries added AFTER we started
SEEN_LOG_LINES=$(
    "$PACT" log "$PROJECT" 2>&1 \
        | sgrep -c '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T' \
        || echo 0
)
echo "[$(ts)] starting — $SEEN_LOG_LINES existing log entries already recorded (will show only new ones)"
sep

LAST_AUDIT_TS=$(last_audit_ts)

while true; do
    STATUS=$("$PACT" status "$PROJECT" 2>&1) || STATUS="ERROR: pact status failed"
    PHASE=$(echo "$STATUS" | sgrep -oE 'Phase: [a-z_]+' | head -1 | awk '{print $2}')

    print_status "$STATUS"

    # ── show NEW log entries (incremental, not repeated) ──────
    print_new_log_entries

    # ── show component tree during build phases ───────────────
    if [[ "$PHASE" == "implement" || "$PHASE" == "integrate" ]]; then
        print_components
    fi

    # ── auto-handle pauses ────────────────────────────────────
    if echo "$STATUS" | cgrep -q "Interview questions pending"; then
        echo "[$(ts)] → INTERVIEW PAUSE — running: pact approve"
        "$PACT" approve "$PROJECT" 2>&1 | sgrep -E 'Q:|Daemon|approved' | head -6 || true
        LAST_AUDIT_TS=""
    fi

    if echo "$STATUS" | cgrep -qiE 'Health: (CRITICAL|DEGRADED)'; then
        echo "[$(ts)] → HEALTH GATE — running: pact resume"
        "$PACT" resume "$PROJECT" 2>&1 || true
        LAST_AUDIT_TS=""
    fi

    # ── silent-hang detection ─────────────────────────────────
    if echo "$STATUS" | cgrep -q "Daemon: running" && echo "$STATUS" | cgrep -q "active"; then
        CURRENT_AUDIT_TS=$(last_audit_ts)
        if [[ -n "$CURRENT_AUDIT_TS" && -n "$LAST_AUDIT_TS" ]]; then
            if [[ "$CURRENT_AUDIT_TS" == "$LAST_AUDIT_TS" ]]; then
                LAST_EPOCH=$(iso_to_epoch "$LAST_AUDIT_TS")
                NOW_EPOCH=$(date '+%s')
                SILENT_SECS=$(( NOW_EPOCH - LAST_EPOCH ))
                if (( SILENT_SECS >= STUCK_TIMEOUT )); then
                    echo "[$(ts)] ⚠  SILENT HANG — no new entries for ${SILENT_SECS}s — restarting"
                    DPID=$(echo "$STATUS" | sgrep -oE 'PID [0-9]+' | awk '{print $2}')
                    if [[ -n "$DPID" ]]; then
                        kill "$DPID" 2>/dev/null || true
                        sleep 2
                    fi
                    "$PACT" daemon "$PROJECT" &
                    sleep 4
                    "$PACT" resume "$PROJECT" 2>/dev/null || true
                    echo "[$(ts)] daemon restarted after hang"
                    LAST_AUDIT_TS=""
                else
                    echo "[$(ts)] ℹ  no new log entries for ${SILENT_SECS}s (restart at ${STUCK_TIMEOUT}s)"
                fi
            else
                LAST_AUDIT_TS="$CURRENT_AUDIT_TS"
            fi
        elif [[ -n "$CURRENT_AUDIT_TS" ]]; then
            LAST_AUDIT_TS="$CURRENT_AUDIT_TS"
        fi
    fi

    # ── restart daemon if dead ────────────────────────────────
    if echo "$STATUS" | cgrep -qiE "Daemon: (stopped|not running)|no daemon|ERROR: pact status failed"; then
        echo "[$(ts)] ⚠  daemon dead — restarting..."
        "$PACT" daemon "$PROJECT" &
        sleep 4
        "$PACT" resume "$PROJECT" 2>/dev/null || true
        echo "[$(ts)] daemon restarted"
        LAST_AUDIT_TS=""
    fi

    # ── terminal states ───────────────────────────────────────
    if echo "$STATUS" | cgrep -qE '^\[[0-9a-f]+\] (complete|certified)'; then
        sep
        echo "[$(ts)] ✅  BUILD COMPLETE"
        sep
        print_new_log_entries
        print_components
        exit 0
    fi

    if echo "$STATUS" | cgrep -qE '^\[[0-9a-f]+\] failed'; then
        sep
        echo "[$(ts)] ❌  BUILD FAILED"
        sep
        print_new_log_entries
        exit 1
    fi

    sleep "$INTERVAL"
done
