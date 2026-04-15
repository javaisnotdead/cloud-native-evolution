#!/usr/bin/env bash
# cache-density-benchmark.sh - measures memory and GC impact of Compact Object Headers
#
# Scenario: Spring Boot app with Caffeine cache holding 500k cached order entities.
# Same container memory limit, COH on vs off. Measures:
#   - JVM heap used (after forced GC via MemoryMXBean)
#   - RSS (actual process memory from /proc/self/status)
#   - How many replicas fit in a fixed node budget (e.g. 8 GB)
#   - GC collection count and pause times (via /actuator/metrics after 5-min load test)
#
# Flow per mode: build → start app → populate cache → run hey load test → collect metrics
#
# Usage: ./cache-density-benchmark.sh [default|compact|all]
# Default: all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RESULTS_DIR="$ROOT_DIR/results"

PORT=8080
HEALTH_URL="http://localhost:$PORT/actuator/health"
METRICS_URL="http://localhost:$PORT/actuator/metrics"

HEALTH_TIMEOUT=120
CACHE_ENTRIES="${CACHE_ENTRIES:-500000}"

LOAD_DURATION="${LOAD_DURATION:-60s}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-200}"

APP_CONTAINER="coh-bench-app"
APP_IMAGE="coh-bench-app-img"
HEY_IMAGE="bench-hey"
NETWORK="coh-bench-net"

# Container limits - simulates a Kubernetes pod
CONTAINER_MEMORY="768m"
CONTAINER_CPUS="2"
JVM_XMX="512m"

# Node budget for replica calculation
NODE_MEMORY_GB=8

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────

log()     { echo "[coh-cache] $*" >&2; }
log_sep() { echo "────────────────────────────────────────────────────" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

build() {
    log "Building Docker images..."
    docker build -f "$ROOT_DIR/Dockerfile.app" -t "$APP_IMAGE" "$ROOT_DIR" >&2
    docker build -f "$ROOT_DIR/Dockerfile.hey" -t "$HEY_IMAGE" "$ROOT_DIR" >&2
    docker network create "$NETWORK" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# App lifecycle
# ─────────────────────────────────────────────────────────────────────────────

start_app() {
    local mode="$1"
    local java_opts="-Xmx${JVM_XMX} -XX:+UseZGC"

    if [ "$mode" = "compact" ]; then
        java_opts="$java_opts -XX:+UseCompactObjectHeaders"
        log "Starting app: COH ON (8-byte headers)"
    else
        java_opts="$java_opts -XX:-UseCompactObjectHeaders"
        log "Starting app: COH OFF (12-byte headers)"
    fi

    docker rm -f "$APP_CONTAINER" 2>/dev/null || true

    MSYS_NO_PATHCONV=1 docker run -d \
        --name "$APP_CONTAINER" \
        --network "$NETWORK" \
        -p "${PORT}:${PORT}" \
        --memory "$CONTAINER_MEMORY" \
        --cpus "$CONTAINER_CPUS" \
        -e "JAVA_OPTS=${java_opts}" \
        "$APP_IMAGE" \
        > /dev/null

    if ! wait_for_health; then
        log "ERROR: App failed to start."
        docker logs "$APP_CONTAINER" 2>&1 | tail -30 >&2
        docker rm -f "$APP_CONTAINER" 2>/dev/null || true
        exit 1
    fi

    log "App ready"
}

stop_app() {
    docker rm -f "$APP_CONTAINER" > /dev/null 2>&1 || true
}

wait_for_health() {
    local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
    while ! curl -sf "$HEALTH_URL" > /dev/null 2>&1; do
        if [ "$(date +%s)" -gt "$deadline" ]; then
            return 1
        fi
        sleep 0.5
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Populate cache and measure
# ─────────────────────────────────────────────────────────────────────────────

measure_mode() {
    local mode="$1"

    start_app "$mode"

    log "Populating cache with $CACHE_ENTRIES entries..."
    local response
    response=$(curl -sf -X POST "http://localhost:$PORT/cache/populate?count=$CACHE_ENTRIES" \
               -H "Content-Type: application/json" 2>&1)

    log "Populate response: $response"

    # Read stats (heap + RSS after GC)
    local stats
    stats=$(curl -sf "http://localhost:$PORT/cache/stats" 2>&1)
    log "Stats: $stats"

    # Run load test to generate GC pressure on a full cache
    log "Running load test ($LOAD_DURATION, $LOAD_CONCURRENCY concurrent) on populated cache..."
    local load_url="http://$APP_CONTAINER:$PORT/cache/250000"
    docker run --rm --network "$NETWORK" "$HEY_IMAGE" \
        -z "$LOAD_DURATION" -c "$LOAD_CONCURRENCY" -t 10 \
        "$load_url" > "$RESULTS_DIR/cache-${mode}-hey.txt" 2>&1
    log "Load test complete"

    # Collect GC metrics after load
    local gc_json
    gc_json=$(curl -sf "$METRICS_URL/jvm.gc.pause" 2>/dev/null || echo "{}")
    local gc_count gc_total gc_max
    gc_count=$(echo "$gc_json" | grep -oP '"statistic":"COUNT","value":\K[0-9]+(\.[0-9]+)?' || echo "N/A")
    gc_total=$(echo "$gc_json" | grep -oP '"statistic":"TOTAL_TIME","value":\K[0-9]+(\.[0-9]+)?' || echo "N/A")
    gc_max=$(echo "$gc_json" | grep -oP '"statistic":"MAX","value":\K[0-9]+(\.[0-9]+)?' || echo "N/A")
    log "GC: count=$gc_count total=${gc_total}s max=${gc_max}s"

    # Re-read stats after load (heap may have changed)
    local stats_after
    stats_after=$(curl -sf "http://localhost:$PORT/cache/stats" 2>&1)
    log "Stats after load: $stats_after"

    # Docker stats for container memory
    local docker_mem
    docker_mem=$(docker stats --no-stream --format "{{.MemUsage}}" "$APP_CONTAINER" 2>/dev/null)
    log "Docker memory: $docker_mem"

    # Parse values from initial populate response (stable heap after forced GC)
    local heap_mb rss_kb
    heap_mb=$(echo "$response" | grep -oP '"heapUsedMB"\s*:\s*\K[0-9]+' | head -1)
    rss_kb=$(echo "$response" | grep -oP '"rssKB"\s*:\s*\K[0-9]+' | head -1)
    local rss_mb=""
    if [ -n "$rss_kb" ] && [ "$rss_kb" -gt 0 ] 2>/dev/null; then
        rss_mb=$(( rss_kb / 1024 ))
    else
        rss_mb=$(echo "$docker_mem" | grep -oP '^[0-9]+(\.[0-9]+)?' | head -1 | awk '{printf "%d", $1}')
    fi

    # Calculate replicas that fit in NODE_MEMORY_GB
    local replicas="N/A"
    if [ -n "$rss_mb" ] && [ "$rss_mb" -gt 0 ] 2>/dev/null; then
        replicas=$(( NODE_MEMORY_GB * 1024 / rss_mb ))
    fi

    # Save results (added GC columns)
    mkdir -p "$RESULTS_DIR"
    echo "$mode,$CACHE_ENTRIES,$heap_mb,$rss_mb,$replicas,$gc_count,$gc_total,$gc_max,$docker_mem" \
        >> "$RESULTS_DIR/cache-results.csv"

    # Save full response
    {
        echo "=== $mode ==="
        echo "Populate response: $response"
        echo "Stats (pre-load): $stats"
        echo "Stats (post-load): $stats_after"
        echo "Docker: $docker_mem"
        echo ""
        echo "GC pause JSON: $gc_json"
    } > "$RESULTS_DIR/cache-${mode}-detail.txt"

    stop_app
}

# ─────────────────────────────────────────────────────────────────────────────
# Results
# ─────────────────────────────────────────────────────────────────────────────

print_results() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "  COMPACT OBJECT HEADERS - CACHE DENSITY BENCHMARK"
    echo "  JDK 26, Spring Boot 4.0.4, Caffeine cache, ZGC"
    echo "  Container: ${CONTAINER_CPUS} CPU, ${CONTAINER_MEMORY} RAM, JVM -Xmx${JVM_XMX}"
    echo "  Cache: ${CACHE_ENTRIES} CachedOrder entries (7 fields each)"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    printf "  %-28s %10s  %10s  %10s  %12s  %12s  %18s\n" \
        "Mode" "Heap (MB)" "RSS (MB)" "GC count" "GC total(s)" "GC max(s)" "Replicas in ${NODE_MEMORY_GB}GB"
    echo "  ───────────────────────────────────────────────────────────────────────────────────────────────────"

    local default_rss="" compact_rss=""

    while IFS=',' read -r mode entries heap_mb rss_mb replicas gc_count gc_total gc_max docker_mem; do
        local label
        case "$mode" in
            default) label="COH OFF (12-byte header)"; default_rss="$rss_mb" ;;
            compact) label="COH ON  (8-byte header)";  compact_rss="$rss_mb" ;;
            *) continue ;;
        esac
        printf "  %-28s %10s  %10s  %10s  %12s  %12s  %18s\n" \
            "$label" "$heap_mb" "$rss_mb" "$gc_count" "$gc_total" "$gc_max" "$replicas"
    done < "$RESULTS_DIR/cache-results.csv"

    echo "  ───────────────────────────────────────────────────────────────────────────────────────────────────"

    if [ -n "$default_rss" ] && [ -n "$compact_rss" ] && \
       [ "$default_rss" -gt 0 ] 2>/dev/null && [ "$compact_rss" -gt 0 ] 2>/dev/null; then
        local saved_mb=$(( default_rss - compact_rss ))
        local saved_pct=$(( saved_mb * 100 / default_rss ))
        local default_replicas=$(( NODE_MEMORY_GB * 1024 / default_rss ))
        local compact_replicas=$(( NODE_MEMORY_GB * 1024 / compact_rss ))
        local extra_replicas=$(( compact_replicas - default_replicas ))

        echo ""
        echo "  DELTA:"
        echo "  RSS saved:        ${saved_mb} MB (${saved_pct}%)"
        echo "  Extra replicas:   +${extra_replicas} in ${NODE_MEMORY_GB}GB (${default_replicas} -> ${compact_replicas})"
        echo ""
        echo "  One JVM flag. Zero code changes. ${extra_replicas} more pods per node."
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
    stop_app
    docker network rm "$NETWORK" 2>/dev/null || true
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

STEP="${1:-all}"

build

case "$STEP" in
    default)
        rm -f "$RESULTS_DIR/cache-results.csv"
        measure_mode "default"
        ;;
    compact)
        rm -f "$RESULTS_DIR/cache-results.csv"
        measure_mode "compact"
        ;;
    all)
        rm -f "$RESULTS_DIR/cache-results.csv"
        measure_mode "default"
        sleep 3
        measure_mode "compact"
        ;;
    *)
        echo "Usage: $0 [default|compact|all]"
        exit 1
        ;;
esac

print_results
