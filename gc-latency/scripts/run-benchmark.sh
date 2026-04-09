#!/usr/bin/env bash
# ============================================================================
# GC Latency Benchmark: G1 vs Generational ZGC (containerized)
# ============================================================================
#
# Runs Spring Boot payment API under sustained load across three heap/live-data
# scenarios, comparing G1GC against Generational ZGC. App and load generator
# run in Docker containers on the gc-bench-net network, identical pattern to
# the virtual-threads benchmark (Art #5) for consistency across the series.
#
# Prerequisites:
#   - Docker Desktop running
#   - App built: cd app && ./mvnw package -DskipTests  (JAR is mounted from host)
#
# Usage:
#   ./scripts/run-benchmark.sh [duration_seconds] [concurrency] [rate]
#
# Example:
#   ./scripts/run-benchmark.sh 60 200 2000
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
APP_JAR="$APP_DIR/target/gc-latency-benchmark-1.0.0.jar"

DURATION=${1:-60}
CONCURRENCY=${2:-200}
RATE=${3:-2000}
WARMUP_SECONDS=15
RESULTS_DIR="$ROOT_DIR/results/$(date +%Y%m%d-%H%M%S)"

APP_CONTAINER="gc-bench-app"
APP_IMAGE="gc-bench-app-img"
HEY_IMAGE="gc-bench-hey"
NETWORK="gc-bench-net"

APP_PORT=8080
HEALTH_URL="http://localhost:${APP_PORT}/actuator/health"
STATS_URL="http://localhost:${APP_PORT}/api/gc-stats"
FILL_URL="http://localhost:${APP_PORT}/api/stress/fill-cache"
BENCH_URL_CONTAINER="http://${APP_CONTAINER}:${APP_PORT}/api/payments"

PAYMENT_BODY='{"sender":"ACC-1234","receiver":"ACC-5678","amount":149.99,"currency":"EUR"}'

# Scenarios: name | heap | container_memory | fill_entries | fill_value_bytes
# filled-4g:  ~2.5 GB live data in 4 GB heap
# filled-8g:  ~6 GB live data in 8 GB heap
SCENARIOS=(
    "clean-4g|4g|6g|0|0"
    "filled-4g|4g|6g|100000|26214"
    "filled-8g|8g|10g|250000|25165"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn()   { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $*"; }
error()  { echo -e "${RED}[$(date +%H:%M:%S)]${NC} $*"; }
header() { echo -e "\n${BLUE}============================================================${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}============================================================${NC}\n"; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    if ! command -v docker &>/dev/null; then
        error "Docker not found on PATH."
        exit 1
    fi
    log "Duration: ${DURATION}s | Concurrency: ${CONCURRENCY} | Rate: ${RATE} req/s"
}

# ---------------------------------------------------------------------------
# Build the application JAR if missing
# ---------------------------------------------------------------------------
ensure_jar() {
    if [ -f "$APP_JAR" ]; then
        log "JAR found: $APP_JAR"
        return
    fi

    log "JAR not found, building with Maven wrapper..."
    local mvnw="$APP_DIR/mvnw"
    if [ ! -x "$mvnw" ]; then
        chmod +x "$mvnw" 2>/dev/null || true
    fi
    if [ ! -f "$mvnw" ]; then
        error "Maven wrapper not found at $mvnw"
        exit 1
    fi

    (cd "$APP_DIR" && "./mvnw" package -q -DskipTests) || {
        error "Maven build failed"
        exit 1
    }

    if [ ! -f "$APP_JAR" ]; then
        error "Build succeeded but JAR not found at $APP_JAR"
        exit 1
    fi
    log "JAR built: $APP_JAR"
}

# ---------------------------------------------------------------------------
# Path conversion for Docker volume mounts on Git Bash
# ---------------------------------------------------------------------------
to_docker_path() {
    local p="$1"
    if [[ "$p" =~ ^/[a-zA-Z]/ ]]; then
        local drive="${p:1:1}"
        echo "${drive^^}:${p:2}"
    else
        echo "$p"
    fi
}

# ---------------------------------------------------------------------------
# Build Docker images
# ---------------------------------------------------------------------------
build_images() {
    log "Building app Docker image..."
    docker build -f "$ROOT_DIR/Dockerfile.app" -t "$APP_IMAGE" "$ROOT_DIR" >&2

    if ! docker image inspect "$HEY_IMAGE" > /dev/null 2>&1; then
        log "Building hey Docker image..."
        docker build -f "$ROOT_DIR/Dockerfile.hey" -t "$HEY_IMAGE" "$ROOT_DIR" >&2
    else
        log "hey image already built, skipping"
    fi
}

# ---------------------------------------------------------------------------
# PostgreSQL (via docker compose)
# ---------------------------------------------------------------------------
ensure_postgres() {
    log "Starting PostgreSQL..."
    docker compose -f "$ROOT_DIR/docker-compose.yml" up -d postgres >&2

    local waited=0
    until docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T postgres \
        pg_isready -U payments -d payments > /dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [ $waited -ge 30 ]; then
            error "PostgreSQL did not become ready within 30 seconds"
            exit 1
        fi
    done
    log "PostgreSQL ready"
}

# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------
start_app() {
    local gc_name="$1"
    local heap="$2"
    local mem_limit="$3"
    local scenario="$4"

    local gc_flags
    case "$gc_name" in
        g1)  gc_flags="-XX:+UseG1GC -XX:MaxGCPauseMillis=50" ;;
        zgc) gc_flags="-XX:+UseZGC" ;;
        *)   error "Unknown GC: $gc_name"; exit 1 ;;
    esac

    local results_docker="$(to_docker_path "$RESULTS_DIR")"
    local jar_docker="$(to_docker_path "$APP_JAR")"
    local gc_log_name="${scenario}-${gc_name}-gc.log"

    local java_opts="-Xms${heap} -Xmx${heap} ${gc_flags} -Xlog:gc*:file=/gc-logs/${gc_log_name}:time,level,tags"

    log "Starting app: scenario=${scenario} gc=${gc_name} heap=${heap} mem=${mem_limit}"

    docker rm -f "$APP_CONTAINER" > /dev/null 2>&1 || true

    MSYS_NO_PATHCONV=1 docker run -d \
        --name "$APP_CONTAINER" \
        --network "$NETWORK" \
        --memory="$mem_limit" \
        -p "${APP_PORT}:${APP_PORT}" \
        -v "${jar_docker}:/app/app.jar:ro" \
        -v "${results_docker}:/gc-logs" \
        -e "JAVA_OPTS=${java_opts}" \
        -e "SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/payments" \
        -e "SPRING_DATASOURCE_USERNAME=payments" \
        -e "SPRING_DATASOURCE_PASSWORD=payments" \
        "$APP_IMAGE" > /dev/null

    # Wait for health
    local deadline=$(( $(date +%s) + 90 ))
    while ! curl -sf "$HEALTH_URL" > /dev/null 2>&1; do
        if [ "$(date +%s)" -gt "$deadline" ]; then
            error "App failed to start within 90s. Recent logs:"
            docker logs "$APP_CONTAINER" 2>&1 | tail -40 >&2
            docker rm -f "$APP_CONTAINER" > /dev/null 2>&1 || true
            exit 1
        fi
        sleep 1
    done
    log "App container ready"
}

stop_app() {
    if docker inspect "$APP_CONTAINER" > /dev/null 2>&1; then
        docker rm -f "$APP_CONTAINER" > /dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Cache pre-fill (scenarios 2 & 3)
# ---------------------------------------------------------------------------
prefill_cache() {
    local entries="$1"
    local value_bytes="$2"

    if [ "$entries" = "0" ]; then
        return
    fi

    log "Pre-filling long-lived cache: ${entries} x ${value_bytes}B ..."
    curl -sf "${FILL_URL}?entries=${entries}&valueSizeBytes=${value_bytes}" > /dev/null
    sleep 2
    log "Cache filled"
}

# ---------------------------------------------------------------------------
# Warmup
# ---------------------------------------------------------------------------
run_warmup() {
    log "Warmup ${WARMUP_SECONDS}s..."
    docker run --rm --network "$NETWORK" "$HEY_IMAGE" \
        -z "${WARMUP_SECONDS}s" -c 50 \
        -m POST -H "Content-Type: application/json" \
        -d "$PAYMENT_BODY" \
        "$BENCH_URL_CONTAINER" > /dev/null 2>&1 || true
    sleep 2
}

# ---------------------------------------------------------------------------
# Capture GC stats snapshot
# ---------------------------------------------------------------------------
capture_gc_stats() {
    local out="$1"
    curl -sf "$STATS_URL" > "$out" 2>/dev/null || echo "{}" > "$out"
}

# ---------------------------------------------------------------------------
# Actual benchmark run
# ---------------------------------------------------------------------------
run_benchmark() {
    local scenario="$1"
    local gc_name="$2"
    local hey_out="${RESULTS_DIR}/${scenario}-${gc_name}-hey.txt"

    capture_gc_stats "${RESULTS_DIR}/${scenario}-${gc_name}-stats-before.json"

    log "Running: ${DURATION}s, ${CONCURRENCY} concurrent, ${RATE} req/s..."

    local rate_flag=""
    if [ "$RATE" -gt 0 ] 2>/dev/null; then
        rate_flag="-q $RATE"
    fi

    docker run --rm --network "$NETWORK" "$HEY_IMAGE" \
        -z "${DURATION}s" -c "$CONCURRENCY" $rate_flag \
        -m POST -H "Content-Type: application/json" \
        -d "$PAYMENT_BODY" -t 30 \
        "$BENCH_URL_CONTAINER" > "$hey_out" 2>&1

    capture_gc_stats "${RESULTS_DIR}/${scenario}-${gc_name}-stats-after.json"

    log "Results: ${hey_out}"
    grep -E "(Requests/sec|Total:|Slowest|Average|99% in|50% in)" "$hey_out" || true
}

# ---------------------------------------------------------------------------
# Parse GC log for pause stats
# ---------------------------------------------------------------------------
analyze_gc_log() {
    local scenario="$1"
    local gc_name="$2"
    local gc_log="${RESULTS_DIR}/${scenario}-${gc_name}-gc.log"
    local out="${RESULTS_DIR}/${scenario}-${gc_name}-pauses.txt"

    if [ ! -s "$gc_log" ]; then
        echo "No GC log data" > "$out"
        return
    fi

    grep -oE 'Pause[^)]+\)[[:space:]]+[0-9.]+ms' "$gc_log" > "${out}.lines" || true

    if [ -s "${out}.lines" ]; then
        local count max min total
        count=$(wc -l < "${out}.lines")
        max=$(grep -oE '[0-9.]+ms' "${out}.lines" | tr -d 'ms' | sort -n | tail -1)
        min=$(grep -oE '[0-9.]+ms' "${out}.lines" | tr -d 'ms' | sort -n | head -1)
        total=$(grep -oE '[0-9.]+ms' "${out}.lines" | tr -d 'ms' \
                | awk '{s+=$1} END {printf "%.2f", s}')
        {
            echo "=== GC pauses: ${scenario} / ${gc_name} ==="
            echo "Pause count: ${count}"
            echo "Min pause:   ${min}ms"
            echo "Max pause:   ${max}ms"
            echo "Total STW:   ${total}ms"
        } > "$out"
    else
        echo "No STW pauses recorded" > "$out"
    fi

    cat "$out"
}

# ---------------------------------------------------------------------------
# Run one (scenario x gc) combination
# ---------------------------------------------------------------------------
run_combo() {
    local spec="$1"
    local gc_name="$2"

    IFS='|' read -r scenario heap mem entries value_bytes <<< "$spec"

    header "${scenario} / ${gc_name}"

    start_app "$gc_name" "$heap" "$mem" "$scenario"
    prefill_cache "$entries" "$value_bytes"
    run_warmup
    run_benchmark "$scenario" "$gc_name"
    stop_app
    analyze_gc_log "$scenario" "$gc_name"

    log "Cooldown 5s..."
    sleep 5
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
generate_summary() {
    local summary="${RESULTS_DIR}/SUMMARY.md"

    {
        echo "# GC Latency Benchmark Results"
        echo ""
        echo "- **Date:** $(date +%Y-%m-%d\ %H:%M)"
        echo "- **Environment:** Docker (gc-bench-net), Spring Boot 4.0.4, PostgreSQL 17"
        echo "- **Duration:** ${DURATION}s per run | Concurrency: ${CONCURRENCY} | Rate: ${RATE} req/s"
        echo "- **Warmup:** ${WARMUP_SECONDS}s per run"
        echo ""
        echo "## Results"
        echo ""

        for spec in "${SCENARIOS[@]}"; do
            IFS='|' read -r scenario _ _ _ _ <<< "$spec"
            echo "### ${scenario}"
            echo ""
            for gc_name in g1 zgc; do
                echo "#### ${gc_name}"
                echo '```'
                if [ -f "${RESULTS_DIR}/${scenario}-${gc_name}-hey.txt" ]; then
                    grep -E "(Requests/sec|Total:|Slowest|Average|50% in|99% in)" \
                        "${RESULTS_DIR}/${scenario}-${gc_name}-hey.txt" || true
                fi
                echo ""
                if [ -f "${RESULTS_DIR}/${scenario}-${gc_name}-pauses.txt" ]; then
                    cat "${RESULTS_DIR}/${scenario}-${gc_name}-pauses.txt"
                fi
                echo '```'
                echo ""
            done
        done
    } > "$summary"

    log "Summary: $summary"
    cat "$summary"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
cleanup() { stop_app 2>/dev/null || true; }
trap cleanup EXIT

main() {
    header "GC Latency Benchmark (containerized)"
    check_prerequisites
    ensure_jar

    mkdir -p "$RESULTS_DIR"
    log "Results directory: $RESULTS_DIR"

    build_images
    ensure_postgres

    for spec in "${SCENARIOS[@]}"; do
        for gc_name in g1 zgc; do
            run_combo "$spec" "$gc_name"
        done
    done

    generate_summary
    header "Done! Results in ${RESULTS_DIR}/"
}

main
