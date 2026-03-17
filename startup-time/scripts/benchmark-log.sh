#!/usr/bin/env bash
# benchmark-log.sh — measures JVM startup time across optimization steps
#                    using Spring Boot's own log line (no HTTP round-trip).
#
# Uses Spring PetClinic as the benchmark application (cloned automatically
# from GitHub on first run).
#
# Methodology: reads "Started <App> in X.XXX seconds" from application log.
# This captures pure JVM + framework init cost with zero network overhead,
# making it ideal for comparing optimisation steps head-to-head.
#
# Usage: ./benchmark-log.sh [baseline|extracted|cds|appcds|lazy-init|aot|leyden|leyden-lazy|leyden-aot|native|all]
# Default: all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
CDS_DIR="$ROOT_DIR/.cds"
TMP_DIR="$ROOT_DIR/tmp"
MEASURE="$SCRIPT_DIR/measure-log.sh"

PETCLINIC_DIR="$ROOT_DIR/petclinic"
PETCLINIC_REPO="https://github.com/spring-projects/spring-petclinic.git"
JAR_NAME="spring-petclinic-4.0.0-SNAPSHOT.jar"

# Cached artifact paths (outside Maven target/ so mvnw clean won't nuke them)
DEFAULT_JAR="$BUILD_DIR/default/$JAR_NAME"
DEFAULT_EXTRACTED="$BUILD_DIR/default/extracted"
AOT_JAR="$BUILD_DIR/aot/$JAR_NAME"
AOT_EXTRACTED="$BUILD_DIR/aot/extracted"

# On Windows (MSYS/Git Bash) GraalVM produces a .exe binary
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
    NATIVE_BIN="$BUILD_DIR/native/spring-petclinic.exe"
else
    NATIVE_BIN="$BUILD_DIR/native/spring-petclinic"
fi

RUNS="${BENCHMARK_RUNS:-10}"
PORT=8080

STEPS_ALL=(baseline extracted cds appcds lazy-init aot leyden leyden-lazy leyden-aot native)

# ─────────────────────────────────────────────────────────────────────────────
# Logging & formatting
# ─────────────────────────────────────────────────────────────────────────────

log()     { echo "[benchmark] $*" >&2; }
log_sep() { echo "────────────────────────────────────────────────────" >&2; }

pct() {
    local base=$1 val=$2
    [ "$base" -eq 0 ] && echo "n/a" && return
    echo "-$(( (base - val) * 100 / base ))%"
}

print_row() {
    printf "  %-22s %8sms   %s\n" "$1" "$2" "$3"
}

# ─────────────────────────────────────────────────────────────────────────────
# Results persistence — saved to .cds/<step>-log.ms so individual runs accumulate
# ─────────────────────────────────────────────────────────────────────────────

save_result() { mkdir -p "$CDS_DIR"; echo "$2" > "$CDS_DIR/${1}-log.ms"; }
load_result() { local f="$CDS_DIR/${1}-log.ms"; [ -f "$f" ] && cat "$f" || echo ""; }

# ─────────────────────────────────────────────────────────────────────────────
# Median of N numbers
# ─────────────────────────────────────────────────────────────────────────────

median() {
    local arr=("$@")
    local sorted=()
    IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${arr[@]}" | grep -v '^$' | sort -n && printf '\0') || true
    if [ "${#sorted[@]}" -eq 0 ]; then echo "0"; return; fi
    echo "${sorted[$(( ${#sorted[@]} / 2 ))]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# PetClinic setup — clone on first run
# ─────────────────────────────────────────────────────────────────────────────

setup_petclinic() {
    mkdir -p "$TMP_DIR"

    if [ ! -d "$PETCLINIC_DIR" ]; then
        log "Cloning Spring PetClinic..."
        git clone --depth 1 "$PETCLINIC_REPO" "$PETCLINIC_DIR"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Build & cache — all ensure_* functions are idempotent
# ─────────────────────────────────────────────────────────────────────────────

MVNW_OPTS="-q -DskipTests -Dcheckstyle.skip -Dspring-javaformat.skip"

ensure_default_jar() {
    [ -f "$DEFAULT_JAR" ] && return 0
    setup_petclinic
    log "Building PetClinic JAR..."
    # shellcheck disable=SC2086
    (cd "$PETCLINIC_DIR" && ./mvnw package $MVNW_OPTS)
    mkdir -p "$(dirname "$DEFAULT_JAR")"
    cp "$PETCLINIC_DIR/target/$JAR_NAME" "$DEFAULT_JAR"
    # Purge stale CDS/Leyden archives — they embed JAR timestamp/size in the header
    rm -f "$CDS_DIR"/app-cds.jsa "$CDS_DIR"/leyden.aot "$CDS_DIR"/leyden.aotconf
    log "JAR cached: $DEFAULT_JAR"
}

ensure_default_extracted() {
    ensure_default_jar
    [ -d "$DEFAULT_EXTRACTED" ] && return 0
    log "Extracting default JAR..."
    mkdir -p "$DEFAULT_EXTRACTED"
    java -Djarmode=tools -jar "$DEFAULT_JAR" extract \
        --destination "$DEFAULT_EXTRACTED" > "$TMP_DIR/extract-default.log" 2>&1
    log "Extracted to: $DEFAULT_EXTRACTED"
}

ensure_aot_jar() {
    [ -f "$AOT_JAR" ] && return 0
    setup_petclinic
    log "Building PetClinic JAR with Spring AOT processing..."
    # shellcheck disable=SC2086
    (cd "$PETCLINIC_DIR" && ./mvnw clean compile spring-boot:process-aot package $MVNW_OPTS)
    mkdir -p "$(dirname "$AOT_JAR")"
    cp "$PETCLINIC_DIR/target/$JAR_NAME" "$AOT_JAR"
    # Purge stale AOT CDS/Leyden archives
    rm -f "$CDS_DIR"/aot-cds.jsa "$CDS_DIR"/leyden-aot.aot "$CDS_DIR"/leyden-aot.aotconf
    log "AOT JAR cached: $AOT_JAR"
}

ensure_aot_extracted() {
    ensure_aot_jar
    [ -d "$AOT_EXTRACTED" ] && return 0
    log "Extracting AOT JAR..."
    mkdir -p "$AOT_EXTRACTED"
    java -Djarmode=tools -jar "$AOT_JAR" extract \
        --destination "$AOT_EXTRACTED" > "$TMP_DIR/extract-aot.log" 2>&1
    log "Extracted to: $AOT_EXTRACTED"
}

ensure_native() {
    [ -f "$NATIVE_BIN" ] && return 0
    setup_petclinic
    log "Building GraalVM native image — this takes 4-6 minutes..."
    # On Windows, native-image ships as a .cmd; the bare name is a broken shim in Git Bash
    if ! command -v native-image &>/dev/null && ! command -v native-image.cmd &>/dev/null; then
        log "ERROR: 'native-image' not found. Install GraalVM and run: gu install native-image"
        exit 1
    fi
    (cd "$PETCLINIC_DIR" && ./mvnw -Pnative native:compile -DskipTests \
        -Dcheckstyle.skip -Dspring-javaformat.skip)
    local src_bin
    if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
        src_bin="$PETCLINIC_DIR/target/spring-petclinic.exe"
    else
        src_bin="$PETCLINIC_DIR/target/spring-petclinic"
    fi
    if [ ! -f "$src_bin" ]; then
        log "ERROR: native binary not found at $src_bin after build"
        exit 1
    fi
    mkdir -p "$(dirname "$NATIVE_BIN")"
    cp "$src_bin" "$NATIVE_BIN"
    log "Native binary cached: $NATIVE_BIN"
}

# ─────────────────────────────────────────────────────────────────────────────
# CDS archive generation
# ─────────────────────────────────────────────────────────────────────────────

generate_archive() {
    local extracted_dir="$1"
    local archive="$2"
    local jvm_opts="${3:-}"

    mkdir -p "$CDS_DIR"
    log "Generating AppCDS archive: $(basename "$archive")"

    local cds_rel
    cds_rel=$(realpath --relative-to="$extracted_dir" "$CDS_DIR")

    # Spring Boot 3.3+ provides a clean way to generate CDS archives at exit
    # shellcheck disable=SC2086
    (cd "$extracted_dir" && java $jvm_opts \
         -XX:ArchiveClassesAtExit="$cds_rel/$(basename "$archive")" \
         -Dspring.context.exit=onRefresh \
         -jar "$JAR_NAME" > "$TMP_DIR/petclinic-training.log" 2>&1) || {
         log "ERROR: archive generation failed. Check $TMP_DIR/petclinic-training.log"
         exit 1
    }

    log "Archive ready: $archive"
}

# ─────────────────────────────────────────────────────────────────────────────
# Hey download (for Leyden training load)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
    HEY_BIN="$TMP_DIR/hey_windows_amd64.exe"
    HEY_URL="https://hey-release.s3.us-east-2.amazonaws.com/hey_windows_amd64"
elif [[ "$(uname -s)" == Darwin* ]]; then
    if [[ "$(uname -m)" == "arm64" ]]; then
        HEY_BIN="$TMP_DIR/hey_darwin_arm64"
        HEY_URL="https://hey-release.s3.us-east-2.amazonaws.com/hey_darwin_arm64"
    else
        HEY_BIN="$TMP_DIR/hey_darwin_amd64"
        HEY_URL="https://hey-release.s3.us-east-2.amazonaws.com/hey_darwin_amd64"
    fi
else
    HEY_BIN="$TMP_DIR/hey_linux_amd64"
    HEY_URL="https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64"
fi

TRAINING_PORT=8080
TRAINING_DURATION="120s"
TRAINING_CONCURRENCY=10
TRAINING_ENDPOINT="http://localhost:$TRAINING_PORT/vets"
HEALTH_URL="http://localhost:$TRAINING_PORT/actuator/health"
HEALTH_TIMEOUT=60

ensure_hey() {
    mkdir -p "$TMP_DIR"
    if [ ! -f "$HEY_BIN" ]; then
        log "Downloading 'hey' load testing tool..."
        curl -sL "$HEY_URL" -o "$HEY_BIN"
        chmod +x "$HEY_BIN"
    fi
}

wait_for_health() {
    local url="$1"
    local timeout="$2"
    local deadline=$(( $(date +%s) + timeout ))
    while ! curl -sf "$url" > /dev/null 2>&1; do
        if [ "$(date +%s)" -gt "$deadline" ]; then
            log "ERROR: Health check timed out after ${timeout}s"
            return 1
        fi
        sleep 0.5
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Leyden AOT Cache generation (JEP 514 one-step workflow)
# ─────────────────────────────────────────────────────────────────────────────

generate_leyden_cache() {
    local extracted_dir="$1"
    local cache="$2"
    local jvm_opts="${3:-}"

    mkdir -p "$CDS_DIR"
    ensure_hey

    log "Leyden training run: $(basename "$cache")"
    log "Starting app with AOTCacheOutput on port $TRAINING_PORT..."

    # JEP 514 (JDK 25): AOTCacheOutput combines record + create in one run.
    # The app must handle real requests so JEP 515 can record method profiles.
    # +AOTClassLinking (JEP 483): pre-links and pre-verifies classes in cache,
    # so the JVM skips these steps at startup.
    # Cache is written automatically on JVM shutdown.
    local training_pid=""
    # shellcheck disable=SC2086
    cd "$extracted_dir"
    java $jvm_opts \
         -XX:AOTCacheOutput="$cache" \
         -XX:+AOTClassLinking \
         -jar "$JAR_NAME" --server.port="$TRAINING_PORT" \
         > "$TMP_DIR/leyden-training.log" 2>&1 &
    training_pid=$!
    cd "$OLDPWD"

    if ! wait_for_health "$HEALTH_URL" "$HEALTH_TIMEOUT"; then
        kill "$training_pid" 2>/dev/null || true
        log "ERROR: Training app failed to start. Check $TMP_DIR/leyden-training.log"
        exit 1
    fi

    log "Sending ${TRAINING_DURATION} of load to build method profiles..."
    "$HEY_BIN" -z "$TRAINING_DURATION" -c "$TRAINING_CONCURRENCY" \
        "$TRAINING_ENDPOINT" > "$TMP_DIR/leyden-training-load.log" 2>&1

    log "Stopping training app via actuator shutdown..."
    local shutdown_url="http://localhost:$TRAINING_PORT/actuator/shutdown"
    curl -sf -X POST "$shutdown_url" > /dev/null 2>&1 || true

    # Wait for JVM to write cache and exit
    local waited=0
    while kill -0 "$training_pid" 2>/dev/null && [ $waited -lt 30 ]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    # Force kill if still alive after 15s
    if kill -0 "$training_pid" 2>/dev/null; then
        log "WARNING: Graceful shutdown timed out, force killing..."
        kill -9 "$training_pid" 2>/dev/null || true
    fi
    wait "$training_pid" 2>/dev/null || true

    if [ ! -f "$cache" ]; then
        log "ERROR: AOT cache not created at $cache"
        log "Check $TMP_DIR/leyden-training.log"
        exit 1
    fi

    log "Leyden cache ready: $cache ($(du -h "$cache" | cut -f1))"
}

ensure_leyden_cache() {
    ensure_default_extracted
    local cache="$CDS_DIR/leyden.aot"
    [ -f "$cache" ] && return 0
    generate_leyden_cache "$DEFAULT_EXTRACTED" "$cache"
}

ensure_leyden_aot_cache() {
    ensure_aot_extracted
    local cache="$CDS_DIR/leyden-aot.aot"
    [ -f "$cache" ] && return 0
    generate_leyden_cache "$AOT_EXTRACTED" "$cache" "-Dspring.aot.enabled=true"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run a single step N times, return median
# ─────────────────────────────────────────────────────────────────────────────

run_step() {
    local name="$1"
    local cmd="$2"
    local workdir="${3:-}"
    local times=()

    log_sep
    log "Step: $name ($RUNS runs)"

    for i in $(seq 1 "$RUNS"); do
        local t
        t=$("$MEASURE" "$cmd" "$PORT" "$workdir")
        times+=("$t")
        printf "  [benchmark]   run %2d: %sms\n" "$i" "$t" >&2
        #let CPU cool down after each run
        sleep 2
    done

    local med
    med=$(median "${times[@]}")
    log "Median: ${med}ms"
    echo "$med"
}

# ─────────────────────────────────────────────────────────────────────────────
# Individual steps
# ─────────────────────────────────────────────────────────────────────────────

step_baseline() {
    ensure_default_jar
    local result
    result=$(run_step "baseline" \
        "java -Xshare:off -jar $DEFAULT_JAR --server.port=$PORT")
    save_result "baseline" "$result"
}

step_extracted() {
    ensure_default_extracted
    local result
    result=$(run_step "extracted" \
        "java -Xshare:off -jar $JAR_NAME --server.port=$PORT" \
        "$DEFAULT_EXTRACTED")
    save_result "extracted" "$result"
}

step_cds() {
    ensure_default_extracted
    local result
    result=$(run_step "cds" \
        "java -Xshare:on -jar $JAR_NAME --server.port=$PORT" \
        "$DEFAULT_EXTRACTED")
    save_result "cds" "$result"
}

step_appcds() {
    ensure_default_extracted
    local archive="$CDS_DIR/app-cds.jsa"
    if [ ! -f "$archive" ]; then
        generate_archive "$DEFAULT_EXTRACTED" "$archive"
    fi

    local cds_rel
    cds_rel=$(realpath --relative-to="$DEFAULT_EXTRACTED" "$CDS_DIR")

    local result
    result=$(run_step "appcds" \
        "java -Xshare:on -XX:SharedArchiveFile=$cds_rel/app-cds.jsa -jar $JAR_NAME --server.port=$PORT" \
        "$DEFAULT_EXTRACTED")
    save_result "appcds" "$result"
}

step_lazy_init() {
    ensure_default_extracted
    local archive="$CDS_DIR/app-cds.jsa"
    if [ ! -f "$archive" ]; then
        generate_archive "$DEFAULT_EXTRACTED" "$archive" "-Dspring.main.lazy-initialization=true"
    fi

    local cds_rel
    cds_rel=$(realpath --relative-to="$DEFAULT_EXTRACTED" "$CDS_DIR")

    local result
    result=$(run_step "lazy-init" \
        "java -Xshare:on -XX:SharedArchiveFile=$cds_rel/app-cds.jsa \
         -Dspring.main.lazy-initialization=true \
         -jar $JAR_NAME --server.port=$PORT" \
        "$DEFAULT_EXTRACTED")
    save_result "lazy-init" "$result"
}

step_aot() {
    ensure_aot_extracted
    local archive="$CDS_DIR/aot-cds.jsa"
    if [ ! -f "$archive" ]; then
        generate_archive "$AOT_EXTRACTED" "$archive" "-Dspring.aot.enabled=true"
    fi

    local cds_rel
    cds_rel=$(realpath --relative-to="$AOT_EXTRACTED" "$CDS_DIR")

    local result
    result=$(run_step "aot" \
        "java -Dspring.aot.enabled=true \
         -Xshare:on -XX:SharedArchiveFile=$cds_rel/aot-cds.jsa \
         -Dspring.main.lazy-initialization=true \
         -jar $JAR_NAME --server.port=$PORT" \
        "$AOT_EXTRACTED")
    save_result "aot" "$result"
}

step_leyden() {
    ensure_leyden_cache
    local result
    result=$(run_step "leyden" \
        "java -XX:AOTCache=$CDS_DIR/leyden.aot -XX:AOTMode=on -XX:+AOTClassLinking \
         -jar $JAR_NAME --server.port=$PORT" \
        "$DEFAULT_EXTRACTED")
    save_result "leyden" "$result"
}

step_leyden_lazy() {
    ensure_leyden_cache
    local result
    result=$(run_step "leyden-lazy" \
        "java -XX:AOTCache=$CDS_DIR/leyden.aot -XX:AOTMode=on -XX:+AOTClassLinking \
         -Dspring.main.lazy-initialization=true \
         -jar $JAR_NAME --server.port=$PORT" \
        "$DEFAULT_EXTRACTED")
    save_result "leyden-lazy" "$result"
}

step_leyden_aot() {
    ensure_leyden_aot_cache
    local result
    result=$(run_step "leyden-aot" \
        "java -Dspring.aot.enabled=true \
         -XX:AOTCache=$CDS_DIR/leyden-aot.aot -XX:AOTMode=on -XX:+AOTClassLinking \
         -Dspring.main.lazy-initialization=true \
         -jar $JAR_NAME --server.port=$PORT" \
        "$AOT_EXTRACTED")
    save_result "leyden-aot" "$result"
}

step_native() {
    ensure_native
    local result
    result=$(run_step "native" "$NATIVE_BIN --server.port=$PORT")
    save_result "native" "$result"
}

# ─────────────────────────────────────────────────────────────────────────────
# Results table with ASCII Chart
# ─────────────────────────────────────────────────────────────────────────────

print_results() {
    local baseline
    baseline=$(load_result "baseline")

    echo ""
    echo "══════════════════ BENCHMARK RESULTS ══════════════════"
    echo "  (Spring Boot self-reported — no HTTP overhead)"
    printf "  %-20s %10s   %s\n" "Optimization Step" "Startup" "Improvement"
    echo "───────────────────────────────────────────────────────"

    # Collect data and find max for chart scaling
    local -a labels=()
    local -a values=()
    local max_val=0

    for step in "${STEPS_ALL[@]}"; do
        local val
        val=$(load_result "$step")
        if [ -n "$val" ]; then
            labels+=("$step")
            values+=("$val")
            if [ "$val" -gt "$max_val" ]; then max_val=$val; fi
        fi
    done

    # Draw rows with bar chart
    local bar_max_width=30
    [ "$max_val" -eq 0 ] && max_val=1

    for i in "${!labels[@]}"; do
        local label="${labels[$i]}"
        local val="${values[$i]}"
        
        # Calculate bar
        local bar_size=$(( val * bar_max_width / max_val ))
        local bar=""
        for ((j=0; j<bar_size; j++)); do bar="${bar}█"; done
        
        # Display row
        local pct_label
        pct_label=$(pct "${baseline:-0}" "$val")
        
        printf "  %-20s %7sms  %-6s  %s\n" "$label" "$val" "($pct_label)" "$bar"
    done

    echo "═══════════════════════════════════════════════════════"
    echo "  Medians from $RUNS runs. Generated for Java 25 & Spring Boot 4."
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

STEP="${1:-all}"

case "$STEP" in
    baseline)    step_baseline ;;
    extracted)   step_extracted ;;
    cds)         step_cds ;;
    appcds)      step_appcds ;;
    lazy-init)   step_lazy_init ;;
    aot)         step_aot ;;
    leyden)      step_leyden ;;
    leyden-lazy) step_leyden_lazy ;;
    leyden-aot)  step_leyden_aot ;;
    native)      step_native ;;
    all)
        step_baseline
        step_extracted
        step_cds
        step_appcds
        step_lazy_init
        step_aot
        step_leyden
        step_leyden_lazy
        step_leyden_aot
        step_native
        ;;
    *)
        echo "Usage: $0 [baseline|extracted|cds|appcds|lazy-init|aot|leyden|leyden-lazy|leyden-aot|native|all]"
        echo "Default: all"
        exit 1
        ;;
esac

print_results
