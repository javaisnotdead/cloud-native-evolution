# GC Latency Benchmark: G1 vs Generational ZGC

Companion benchmark for Cloud Native Evolution - Article 6: [Generational ZGC and the End of GC Pauses](https://www.javaisnotdead.com/generational-zgc-vs-g1gc/)

## What this measures

A Spring Boot payment processing API under sustained load, comparing two garbage collectors across three heap/live-data scenarios:

| Scenario | Heap | Pre-loaded live data |
|----------|------|----------------------|
| `clean-4g`  | 4 GB | none (baseline) |
| `filled-4g` | 4 GB | ~2.5 GB long-lived cache |
| `filled-8g` | 8 GB | ~6 GB long-lived cache |

| Collector | JVM flags |
|-----------|-----------|
| G1GC | `-XX:+UseG1GC -XX:MaxGCPauseMillis=50` |
| Generational ZGC | `-XX:+UseZGC` |

Note: On JDK 24 and later, ZGC is always generational (JEP 474). The `-XX:+ZGenerational` flag was removed.

The payment endpoint allocates ~50-100KB of short-lived objects per request (fraud check, risk scoring, compliance hashing, audit trail), generating enough allocation pressure to trigger frequent GC cycles. Pre-loaded scenarios fill the long-lived cache before the run starts, simulating an in-memory dataset that survives many collection cycles.

## Architecture

Both the application and the load generator run in Docker containers on a shared `gc-bench-net` network. PostgreSQL runs in its own container via `docker-compose`. GC logs are written into a host-mounted volume for offline analysis. This mirrors the setup used in the Virtual Threads benchmark (Article #5) for consistency across the series.

```
┌────────────────┐    ┌────────────────┐    ┌────────────────┐
│   bench-hey    │───▶│  gc-bench-app  │───▶│    postgres    │
│   (load gen)   │    │  (Spring Boot) │    │     (JPA)      │
└────────────────┘    └────────────────┘    └────────────────┘
                             │
                             ▼
                       results/<ts>/
                       (GC logs, hey output, summary)
```

## Prerequisites

- Docker Desktop running
- JDK 25 on PATH (the script uses the bundled Maven wrapper to build the JAR if it's missing - JDK is needed only for that initial build)

## Quick start

```bash
chmod +x scripts/run-benchmark.sh
./scripts/run-benchmark.sh                  # defaults: 60s, 200 concurrent, 2000 req/s
./scripts/run-benchmark.sh 60 200 2000      # explicit args

# Results land in results/<timestamp>/
```

That's the whole flow. The script:
1. Builds the application JAR with `./mvnw package -DskipTests` if it doesn't already exist
2. Builds `gc-bench-app-img` and `gc-bench-hey` Docker images (cached after the first run)
3. Starts PostgreSQL via `docker compose up -d postgres`
4. For each scenario × collector combination:
   - starts the app container with the right `-Xmx` and GC flags
   - pre-fills the long-lived cache via `/api/stress/fill-cache` (when applicable)
   - runs a 15s warmup
   - runs `hey` against `/api/payments` for the configured duration
   - captures GC stats before and after
   - parses the GC log for pause statistics
5. Writes a `SUMMARY.md` in the results directory

## Endpoints

| Endpoint | Purpose |
|----------|---------|
| `POST /api/payments` | Main benchmark endpoint (allocation-heavy payment processing) |
| `GET /api/gc-stats` | Current heap and GC MXBean snapshot |
| `GET /api/stress/firehose?sizeKb=64` | Pure allocation pressure (one-shot) |
| `GET /api/stress/fill-cache?entries=N&valueSizeBytes=B` | Fill long-lived cache |
| `GET /api/stress/lru?valueSizeBytes=4096` | LRU cache (objects promote then die) |
| `GET /api/stress/clear-cache` | Clear long-lived cache |

## Output layout

```
results/20260408-145241/
├── SUMMARY.md                          # human-readable summary
├── clean-4g-g1-gc.log                  # raw GC log
├── clean-4g-g1-hey.txt                 # hey output (RPS, P50/P99 latency)
├── clean-4g-g1-pauses.txt              # parsed pause stats
├── clean-4g-g1-stats-before.json       # GC MXBean snapshot before run
├── clean-4g-g1-stats-after.json        # GC MXBean snapshot after run
├── clean-4g-zgc-*.{log,txt,json}       # same for ZGC
├── filled-4g-{g1,zgc}-*                # filled-4g scenario
└── filled-8g-{g1,zgc}-*                # filled-8g scenario
```

## Tuning the load

The default `200 concurrent / 2000 req/s` configuration deliberately pushes the app close to saturation (the service tops out around 1,950 req/s on a typical dev machine). This exposes GC behavior under pressure. For a less stressed run:

```bash
./scripts/run-benchmark.sh 60 50 500     # 50 concurrent, 500 req/s
```

For a longer soak:

```bash
./scripts/run-benchmark.sh 300 200 2000  # 5-minute runs
```

## Cleanup

```bash
docker compose down                      # stops postgres
docker rm -f gc-bench-app                # if a stale app container remains
docker rmi gc-bench-app-img gc-bench-hey # remove built images
```
