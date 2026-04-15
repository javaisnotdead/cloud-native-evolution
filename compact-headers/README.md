# Compact Object Headers Benchmark

Companion code for Cloud Native Evolution - Article 7: [Saving Hundreds of Megabytes You Didn’t Know You Were Wasting](https://www.javaisnotdead.com/compact-object-headers/)

Measures the impact of Compact Object Headers (JEP 450/519) on memory density and GC behavior in a Spring Boot 4 application.

## The workload

A Spring Boot app with a Caffeine cache holding 500,000 `CachedOrder` records (7 fields each: Long, three Strings, Integer, BigDecimal, LocalDateTime). After populating the cache, a 5-minute load test at 200 concurrent connections hits `GET /cache/{id}` to generate allocation pressure on a full heap.

Both runs use identical settings. The only difference is one JVM flag.

## Architecture

```
┌────────────────┐    ┌────────────────┐
│   bench-hey    │───▶│ coh-bench-app  │
│   (load gen)   │    │ (Spring Boot)  │
└────────────────┘    └────────────────┘
                             │
                             ▼
                       results/
                       (heap, RSS, GC metrics)
```

No database. This benchmark isolates memory and GC effects from I/O.

## Requirements

- Docker Desktop running

## Quick start

```bash
cd scripts
./benchmark.sh all
```

The script:
1. Builds Docker images (multi-stage build compiles the JAR inside Docker, no local JDK needed)
2. For each mode (COH off, COH on):
   - starts the app container with ZGC and the appropriate COH flag
   - populates the Caffeine cache with 500k entries via `POST /cache/populate`
   - runs a 5-minute `hey` load test against `GET /cache/250000`
   - collects GC metrics from `/actuator/metrics/jvm.gc.pause`
   - records heap, RSS, and Docker memory usage
4. Prints a comparison table with pod density calculation

Container limits: 2 CPU, 768 MB RAM, JVM `-Xmx512m`, ZGC.

## Endpoints

| Endpoint | Purpose |
|----------|---------|
| `POST /cache/populate?count=N` | Fill Caffeine cache with N entries, force GC, return heap/RSS |
| `GET /cache/{id}` | Read a cached order (benchmark target) |
| `GET /cache/stats` | Current heap and RSS snapshot |
| `GET /actuator/metrics/jvm.gc.pause` | GC collection count and pause times |

## JOL Analysis

Static object layout comparison using [JOL](https://github.com/openjdk/jol). A small program that prints the memory layout of common JDK and domain types with and without compact headers.

```bash
cd jol-analysis
docker build -t jol-analysis .
docker run --rm jol-analysis                                              # default 12-byte headers
docker run --rm jol-analysis -XX:+UseCompactObjectHeaders -jar jol-analysis.jar  # compact 8-byte headers
```

Source: `jol-analysis/src/main/java/com/javaisnotdead/jol/ObjectLayoutAnalysis.java`

## Output layout

```
results/
├── cache-results.csv              # heap, RSS, GC count, GC pause per mode
├── cache-default-detail.txt       # full JSON responses and GC metrics (COH off)
├── cache-compact-detail.txt       # full JSON responses and GC metrics (COH on)
├── cache-default-hey.txt          # hey load test output (COH off)
├── cache-compact-hey.txt          # hey load test output (COH on)
```

JOL output: `jol-analysis/results/compact-headers.txt`

## Structure

```
compact-headers/
  app/                             Caffeine cache benchmark app (Spring Boot 4)
  jol-analysis/                    JOL object layout analysis
  scripts/
    benchmark.sh     Memory + GC benchmark
  results/                         Benchmark outputs
  Dockerfile.app                   Multi-stage build (Maven + Corretto 26)
  Dockerfile.hey                   hey load generator
```

## Cleanup

```bash
docker rm -f coh-bench-app         # if a stale app container remains
docker network rm coh-bench-net    # remove benchmark network
docker rmi coh-bench-app-img       # remove built image
```
