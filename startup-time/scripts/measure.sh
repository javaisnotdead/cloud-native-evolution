#!/usr/bin/env bash
# measure.sh — starts an app, waits for HTTP 200, returns elapsed milliseconds
#
# Usage: measure.sh "<start command>" [port] [workdir]
# Output: elapsed milliseconds (stdout), log messages (stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$ROOT_DIR/tmp"
mkdir -p "$TMP_DIR"
LOGFILE="$TMP_DIR/petclinic-app.log"

CMD="$1"
PORT="${2:-8080}"
WORKDIR="${3:-}"
HEALTH_URL="http://localhost:${PORT}/actuator/health"
TIMEOUT_SECS=30

now_ms() {
    local ns
    ns=$(date +%s%N 2>/dev/null)
    if [[ "$ns" != "%s%N" && -n "$ns" ]]; then
        echo $(( ns / 1000000 ))
    else
        # macOS without coreutils: brew install coreutils
        python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null \
            || echo $(( $(date +%s) * 1000 ))
    fi
}

START=$(now_ms)
DEADLINE=$(( START + TIMEOUT_SECS * 1000 ))

# bash -c "exec" ensures the shell is replaced by the process directly — no
# wrapper bash left alive. eval leaves a bash parent that becomes orphan after
# kill, keeping the port occupied and making run 2+ measure ~30ms (old process).
if [ -n "$WORKDIR" ]; then
    bash -c "cd \"$WORKDIR\" && exec $CMD" > "$LOGFILE" 2>&1 &
else
    bash -c "exec $CMD" > "$LOGFILE" 2>&1 &
fi
APP_PID=$!

while true; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "ERROR: app crashed — check $LOGFILE" >&2
        exit 1
    fi

    NOW=$(now_ms)
    if [ "$NOW" -gt "$DEADLINE" ]; then
        echo "ERROR: timeout after ${TIMEOUT_SECS}s waiting for HTTP 200" >&2
        kill -9 "$APP_PID" 2>/dev/null || true
        exit 1
    fi

    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 0.1 --max-time 0.5 \
        "$HEALTH_URL" 2>/dev/null || echo "000")

    if [ "$STATUS" = "200" ]; then
        break
    fi

    sleep 0.01
done

END=$(now_ms)
ELAPSED=$(( END - START ))

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

echo "$ELAPSED"
