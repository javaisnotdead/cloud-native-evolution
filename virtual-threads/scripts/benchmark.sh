#!/usr/bin/env bash
# benchmark.sh — measures throughput and latency under concurrency
# Compares platform threads, virtual threads, and reactive (WebFlux) in Spring Boot 4
#
# Each POST /orders executes two PostgreSQL round-trips: INSERT + SELECT.
# Runs four concurrency levels (50 / 200 / 500 / 1000) for each mode.
#
# Requirements: JDK 26+, Docker (Maven wrapper included)
#
# Usage: ./benchmark.sh [platform|virtual|virtual-g1|reactive|all|results]
# Default: all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
REACTIVE_APP_DIR="$ROOT_DIR/reactive-app"
MVNW="$ROOT_DIR/mvnw"

# JDK 26 required for the benchmark. Set JAVA_HOME if not already pointing to JDK 26.
export JAVA_HOME="${JAVA_HOME:-/c/dev/java/openjdk-26}"
TMP_DIR="$ROOT_DIR/tmp"
RESULTS_DIR="$ROOT_DIR/.results"

PORT=8080
HEALTH_URL="http://localhost:$PORT/actuator/health"
BENCHMARK_URL_CONTAINER="http://bench-app:$PORT/orders"

REQUEST_BODY='{"customerName":"bench","productName":"widget","quantity":1}'

HEALTH_TIMEOUT=120
WARMUP_DURATION="15s"
WARMUP_CONCURRENCY=10
TEST_DURATION="${BENCHMARK_DURATION:-30s}"
CONCURRENCY_LEVELS=(50 200 500 1000)

APP_CONTAINER="bench-app"
HEY_IMAGE="bench-hey"
APP_IMAGE="bench-app-img"

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────

log()     { echo "[benchmark] $*" >&2; }
log_sep() { echo "────────────────────────────────────────────────────" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites
# ─────────────────────────────────────────────────────────────────────────────

check_prerequisites() {
    if [ ! -f "$MVNW" ]; then
        log "ERROR: Maven wrapper not found at $MVNW"
        exit 1
    fi
    if ! command -v docker &>/dev/null; then
        log "ERROR: Docker not found on PATH."
        exit 1
    fi
    if [ ! -d "$JAVA_HOME/bin" ]; then
        log "ERROR: JAVA_HOME not valid: $JAVA_HOME"
        log "Set JAVA_HOME to a JDK 26+ installation."
        exit 1
    fi
    log "JAVA_HOME: $JAVA_HOME"
}

# ─────────────────────────────────────────────────────────────────────────────
# Build Docker images
# ─────────────────────────────────────────────────────────────────────────────

build_images() {
    log "Building app Docker image..."
    docker build -f "$ROOT_DIR/Dockerfile.app" -t "$APP_IMAGE" "$ROOT_DIR" >&2

    if ! docker image inspect "$HEY_IMAGE" > /dev/null 2>&1; then
        log "Building hey Docker image (downloads hey_linux_amd64)..."
        docker build -f "$ROOT_DIR/Dockerfile.hey" -t "$HEY_IMAGE" "$ROOT_DIR" >&2
    else
        log "hey Docker image already built, skipping."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Build JARs
# ─────────────────────────────────────────────────────────────────────────────

ensure_jar() {
    local jar
    jar=$(find "$APP_DIR/target" -name "virtual-threads-benchmark-*.jar" \
          -not -name "*-plain.jar" 2>/dev/null | head -1)

    if [ -z "$jar" ]; then
        log "Building blocking app JAR..."
        (cd "$APP_DIR" && "$MVNW" package -q -DskipTests)
        jar=$(find "$APP_DIR/target" -name "virtual-threads-benchmark-*.jar" \
              -not -name "*-plain.jar" | head -1)
    fi

    APP_JAR="$jar"
    log "Blocking JAR: $APP_JAR"
}

ensure_reactive_jar() {
    local jar
    jar=$(find "$REACTIVE_APP_DIR/target" -name "reactive-benchmark-*.jar" \
          -not -name "*-plain.jar" 2>/dev/null | head -1)

    if [ -z "$jar" ]; then
        log "Building reactive app JAR..."
        (cd "$REACTIVE_APP_DIR" && "$MVNW" package -q -DskipTests)
        jar=$(find "$REACTIVE_APP_DIR/target" -name "reactive-benchmark-*.jar" \
              -not -name "*-plain.jar" | head -1)
    fi

    REACTIVE_JAR="$jar"
    log "Reactive JAR: $REACTIVE_JAR"
}

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────

ensure_postgres() {
    log "Starting PostgreSQL..."
    docker compose -f "$ROOT_DIR/docker-compose.yml" up -d postgres

    log "Waiting for PostgreSQL to be ready..."
    local waited=0
    until docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T postgres \
        pg_isready -U orders -d orders > /dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [ $waited -ge 30 ]; then
            log "ERROR: PostgreSQL did not become ready in 30 seconds"
            exit 1
        fi
    done
    log "PostgreSQL ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# App lifecycle (runs in Docker container)
# ─────────────────────────────────────────────────────────────────────────────

start_app() {
    local mode="$1"
    local java_opts=""
    local jar_to_mount="$APP_JAR"
    local env_vars=()

    if [ "$mode" = "virtual" ]; then
        java_opts="-Dspring.threads.virtual.enabled=true -XX:+UseZGC"
        env_vars=(-e "SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/orders"
                  -e "SPRING_DATASOURCE_USERNAME=orders"
                  -e "SPRING_DATASOURCE_PASSWORD=orders")
        log "Starting app container: VIRTUAL THREADS (ZGC)"
    elif [ "$mode" = "virtual-g1" ]; then
        java_opts="-Dspring.threads.virtual.enabled=true"
        env_vars=(-e "SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/orders"
                  -e "SPRING_DATASOURCE_USERNAME=orders"
                  -e "SPRING_DATASOURCE_PASSWORD=orders")
        log "Starting app container: VIRTUAL THREADS (G1GC)"
    elif [ "$mode" = "reactive" ]; then
        jar_to_mount="$REACTIVE_JAR"
        env_vars=(-e "SPRING_R2DBC_URL=r2dbc:postgresql://postgres:5432/orders"
                  -e "SPRING_R2DBC_USERNAME=orders"
                  -e "SPRING_R2DBC_PASSWORD=orders")
        log "Starting app container: REACTIVE (WebFlux + R2DBC)"
    else
        env_vars=(-e "SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/orders"
                  -e "SPRING_DATASOURCE_USERNAME=orders"
                  -e "SPRING_DATASOURCE_PASSWORD=orders")
        log "Starting app container: PLATFORM THREADS (max=20, G1GC)"
    fi

    mkdir -p "$TMP_DIR"

    # Remove stale container if any
    docker rm -f "$APP_CONTAINER" 2>/dev/null || true

    # Convert JAR path for Docker volume (Git Bash /c/... → C:/... for Docker Desktop)
    local jar_docker_path="$jar_to_mount"
    if [[ "$jar_docker_path" =~ ^/[a-zA-Z]/ ]]; then
        local drive_letter="${jar_docker_path:1:1}"
        jar_docker_path="${drive_letter^^}:${jar_docker_path:2}"
    fi

    MSYS_NO_PATHCONV=1 docker run -d \
        --name "$APP_CONTAINER" \
        --network bench-net \
        -p "${PORT}:${PORT}" \
        -v "${jar_docker_path}:/app/app.jar:ro" \
        -e "JAVA_OPTS=${java_opts}" \
        "${env_vars[@]}" \
        "$APP_IMAGE" \
        > /dev/null

    if ! wait_for_health "$HEALTH_URL" "$HEALTH_TIMEOUT"; then
        log "ERROR: App failed to start. Fetching container logs..."
        docker logs "$APP_CONTAINER" 2>&1 | tail -50 >&2
        docker rm -f "$APP_CONTAINER" 2>/dev/null || true
        exit 1
    fi

    log "App container ready"
}

stop_app() {
    if docker inspect "$APP_CONTAINER" > /dev/null 2>&1; then
        log "Stopping app container..."
        docker rm -f "$APP_CONTAINER" > /dev/null 2>&1 || true
    fi
}

wait_for_health() {
    local url="$1"
    local timeout="$2"
    local deadline=$(( $(date +%s) + timeout ))
    while ! curl -sf "$url" > /dev/null 2>&1; do
        if [ "$(date +%s)" -gt "$deadline" ]; then
            return 1
        fi
        sleep 0.5
    done
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# hey runner (runs in Docker container on bench-net)
# ─────────────────────────────────────────────────────────────────────────────

run_hey() {
    local label="$1"
    local concurrency="$2"
    local duration="$3"
    local output_file="$TMP_DIR/hey-${label}-c${concurrency}.txt"

    docker run --rm \
        --network bench-net \
        "$HEY_IMAGE" \
        -z "$duration" -c "$concurrency" \
        -m POST \
        -H "Content-Type: application/json" \
        -d "$REQUEST_BODY" \
        -t 10 \
        "$BENCHMARK_URL_CONTAINER" > "$output_file" 2>&1

    echo "$output_file"
}

parse_rps()    { grep "Requests/sec:" "$1" | awk '{printf "%d", $2}'; }
parse_avg_ms() { grep "Average:"      "$1" | awk '{printf "%d", $2 * 1000}'; }
parse_p99_ms() { grep "99% in"        "$1" | awk '{printf "%d", $3 * 1000}'; }

parse_errors() {
    local total success
    total=$(  grep -E "^\s+\[[0-9]+\]" "$1" | awk '{sum+=$2} END {printf "%d", sum+0}')
    success=$(grep -E "^\s+\[2[0-9][0-9]\]" "$1" | awk '{sum+=$2} END {printf "%d", sum+0}')
    echo $(( total - success ))
}

# ─────────────────────────────────────────────────────────────────────────────
# Results persistence
# ─────────────────────────────────────────────────────────────────────────────

save_result() {
    mkdir -p "$RESULTS_DIR"
    echo "${1},${2},${3},${4},${5},${6}" >> "$RESULTS_DIR/results.csv"
}

load_result() {
    grep "^${1},${2}," "$RESULTS_DIR/results.csv" 2>/dev/null | tail -1
}

# ─────────────────────────────────────────────────────────────────────────────
# Run one mode
# ─────────────────────────────────────────────────────────────────────────────

benchmark_mode() {
    local mode="$1"

    start_app "$mode"

    log "Warmup ($WARMUP_DURATION, $WARMUP_CONCURRENCY concurrent)..."
    run_hey "${mode}-warmup" "$WARMUP_CONCURRENCY" "$WARMUP_DURATION" > /dev/null

    for c in "${CONCURRENCY_LEVELS[@]}"; do
        log_sep
        log "[$mode] $c concurrent users, $TEST_DURATION..."

        local output_file
        output_file=$(run_hey "$mode" "$c" "$TEST_DURATION")

        local rps avg p99 errors
        rps=$(parse_rps "$output_file")
        avg=$(parse_avg_ms "$output_file")
        p99=$(parse_p99_ms "$output_file")
        errors=$(parse_errors "$output_file")

        log "  Req/sec: $rps  |  Avg: ${avg}ms  |  P99: ${p99}ms  |  Errors: $errors"
        save_result "$mode" "$c" "$rps" "$avg" "$p99" "$errors"

        sleep 2
    done

    stop_app
}

# ─────────────────────────────────────────────────────────────────────────────
# Results table
# ─────────────────────────────────────────────────────────────────────────────

print_results() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  CONCURRENCY BENCHMARK — JDK 26, Spring Boot 4.0.4, PostgreSQL 17"
    echo "═══════════════════════════════════════════════════════════════════════════"
    printf "  %-24s %8s  %10s  %9s  %9s  %8s\n" \
        "Mode" "Users" "Req/sec" "Avg lat" "P99 lat" "Errors"
    echo "  ───────────────────────────────────────────────────────────────────────"

    local prev_mode=""
    for mode in platform virtual-g1 virtual reactive; do
        for c in "${CONCURRENCY_LEVELS[@]}"; do
            local row
            row=$(load_result "$mode" "$c")
            if [ -n "$row" ]; then
                local rps avg p99 errors
                IFS=',' read -r _ _ rps avg p99 errors <<< "$row"

                local label
                case "$mode" in
                    platform)   label="Platform (20, G1GC)" ;;
                    virtual-g1) label="Virtual (G1GC)" ;;
                    virtual)    label="Virtual (ZGC)" ;;
                    reactive)   label="Reactive (WebFlux)" ;;
                esac

                if [ "$mode" != "$prev_mode" ] && [ -n "$prev_mode" ]; then
                    echo "  ───────────────────────────────────────────────────────────────────────"
                fi

                printf "  %-24s %8s  %10s  %8sms  %8sms  %8s\n" \
                    "$label" "$c" "$rps" "$avg" "$p99" "$errors"
                prev_mode="$mode"
            fi
        done
    done

    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  POST /orders: INSERT + SELECT per request. $TEST_DURATION per scenario."
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

cleanup() { stop_app; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

STEP="${1:-all}"

check_prerequisites
build_images
ensure_postgres

# Build JARs based on which modes will run
case "$STEP" in
    reactive)
        ensure_reactive_jar
        ;;
    all)
        ensure_jar
        ensure_reactive_jar
        ;;
    results)
        ;;
    *)
        ensure_jar
        ;;
esac

case "$STEP" in
    platform)
        rm -f "$RESULTS_DIR/results.csv"
        benchmark_mode "platform"
        ;;
    virtual)
        rm -f "$RESULTS_DIR/results.csv"
        benchmark_mode "virtual"
        ;;
    virtual-g1)
        rm -f "$RESULTS_DIR/results.csv"
        benchmark_mode "virtual-g1"
        ;;
    reactive)
        rm -f "$RESULTS_DIR/results.csv"
        benchmark_mode "reactive"
        ;;
    all)
        rm -f "$RESULTS_DIR/results.csv"
        benchmark_mode "platform"
        sleep 5
        benchmark_mode "virtual-g1"
        sleep 5
        benchmark_mode "virtual"
        sleep 5
        benchmark_mode "reactive"
        ;;
    results)
        ;;
    *)
        echo "Usage: $0 [platform|virtual|virtual-g1|reactive|all|results]"
        exit 1
        ;;
esac

print_results
