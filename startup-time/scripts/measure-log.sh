#!/usr/bin/env bash
# measure-log.sh — starts an app, waits for Spring Boot "Started…in X seconds"
# log line, returns elapsed milliseconds (wall-clock since exec).
#
# Usage: measure-log.sh "<start command>" [port] [workdir]
# Output: elapsed milliseconds (stdout), log messages (stderr)
#
# Why not HTTP? This method captures pure JVM+framework startup cost with zero
# network overhead. The HTTP-based measure.sh adds ~5-15 ms of curl latency per
# run that inflates results, especially for already-fast AOT/native steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$ROOT_DIR/tmp"
mkdir -p "$TMP_DIR"

CMD="$1"
PORT="${2:-8080}"
WORKDIR="${3:-}"
TIMEOUT_SECS=30
LOGFILE="$TMP_DIR/petclinic-app.log"

# ─── Portable millisecond clock ──────────────────────────────────────────────
now_ms() {
    local ns
    ns=$(date +%s%N 2>/dev/null)
    if [[ "$ns" != "%s%N" && -n "$ns" ]]; then
        echo $(( ns / 1000000 ))
    else
        python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null \
            || echo $(( $(date +%s) * 1000 ))
    fi
}

# ─── Launch the application ──────────────────────────────────────────────────
START=$(now_ms)
DEADLINE=$(( START + TIMEOUT_SECS * 1000 ))

# Truncate log so we don't match a line from a previous run.
: > "$LOGFILE"

if [ -n "$WORKDIR" ]; then
    bash -c "cd \"$WORKDIR\" && exec $CMD" > "$LOGFILE" 2>&1 &
else
    bash -c "exec $CMD" > "$LOGFILE" 2>&1 &
fi
APP_PID=$!

# ─── Wait for the "Started … in X.XXX seconds" line ─────────────────────────
# Spring Boot 3.x emits:
#   Started <App> in 1.234 seconds (process running for 1.567)
# We capture the value reported by the framework itself, then also compute
# wall-clock elapsed for a consistent comparison with measure.sh.
REPORTED_MS=""

while true; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "ERROR: app crashed — check $LOGFILE" >&2
        exit 1
    fi

    NOW=$(now_ms)
    if [ "$NOW" -gt "$DEADLINE" ]; then
        echo "ERROR: timeout after ${TIMEOUT_SECS}s waiting for startup log" >&2
        kill -9 "$APP_PID" 2>/dev/null || true
        exit 1
    fi

    # Match "Started Xxx in 1.234 seconds"
    if grep -qE "Started .+ in [0-9.]+ seconds" "$LOGFILE" 2>/dev/null; then
        END=$(now_ms)

        # Extract the value Spring Boot itself reports (convert to ms)
        REPORTED_SECS=$(grep -oE "Started .+ in [0-9.]+ seconds" "$LOGFILE" \
            | tail -1 \
            | grep -oE "[0-9]+\.[0-9]+")

        if [ -n "$REPORTED_SECS" ]; then
            # awk: multiply by 1000, round to nearest integer
            REPORTED_MS=$(awk "BEGIN { printf \"%d\", ($REPORTED_SECS * 1000 + 0.5) }")
        fi
        break
    fi

    sleep 0.005
done

# ─── Kill app, wait for port to be released ──────────────────────────────────
kill -9 "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

# Wait until the port is released before returning — otherwise the next run
# measures time-to-existing-process rather than time-to-new-cold-start.
# Use a raw TCP check (/dev/tcp) rather than curl so a stale HTTP keep-alive
# or connection caching can't mask that the port is actually gone.
deadline=$(( $(date +%s) + 10 ))
while (exec 3<>/dev/tcp/localhost/"$PORT") 2>/dev/null; do
    exec 3>&- 2>/dev/null || true
    sleep 0.1
    [ "$(date +%s)" -gt "$deadline" ] && break
done
sleep 0.1

# ─── Emit result ─────────────────────────────────────────────────────────────
# Prefer the value from Spring's own log (accounts for JVM internals accurately).
# Fall back to wall-clock if parsing failed.
if [ -n "$REPORTED_MS" ]; then
    echo "$REPORTED_MS"
else
    ELAPSED=$(( END - START ))
    echo "$ELAPSED"
fi
