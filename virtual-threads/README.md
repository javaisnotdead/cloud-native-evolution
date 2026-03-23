# Virtual Threads Benchmark

Companion code for Cloud Native Evolution - Article 5: [Virtual Threads: Thread-Per-Request at Scale](https://www.javaisnotdead.com/java-virtual-threads-spring-boot/)

Compares four concurrency approaches on the same workload.

## The workload

`POST /orders` executes two PostgreSQL round-trips (INSERT + SELECT) with a 50ms simulated I/O delay before each database call. Total blocking time per request: 100ms simulated + actual DB time.

The simulated delay runs before the database operation, not during. This means the database connection is held only for the SQL execution, not during the 50ms wait. This design choice is explained in detail in the article.

## Requirements

- JDK 26+ (set `JAVA_HOME`, defaults to `/c/dev/java/openjdk-26`)
- Docker
- Maven wrapper included (`./mvnw`)

## Quick start

Run all four benchmarks:

```bash
./scripts/benchmark.sh all
```

Run a single mode:

```bash
./scripts/benchmark.sh platform
./scripts/benchmark.sh virtual-g1
./scripts/benchmark.sh virtual
./scripts/benchmark.sh reactive
```

Print results from the last run without re-running:

```bash
./scripts/benchmark.sh results
```

Each concurrency level (50, 200, 500, 1000 users) runs for 30 seconds after a 15-second warmup. Override duration with `BENCHMARK_DURATION=60s ./scripts/benchmark.sh all`.

## Project structure

```
virtual-threads/
  app/                    Spring MVC + JDBC (blocking)
  reactive-app/           Spring WebFlux + R2DBC (non-blocking)
  scripts/benchmark.sh    Automated benchmark runner
  docker-compose.yml      PostgreSQL 17
  Dockerfile.app          Amazon Corretto 26 (shared by both apps)
  Dockerfile.hey          Load generator (hey)
```

## How isolation works

Three Docker containers on a shared network (`bench-net`):

1. **postgres** - PostgreSQL 17, `max_connections=500`
2. **bench-app** - the application under test (JAR mounted from host)
3. **hey container** - load generator, created per benchmark run

The load generator runs in its own container on the same Docker network as the application. Requests go through Docker networking (`http://bench-app:8080/orders`).

## Configuration

Both apps use a 20-connection database pool. The blocking app limits Tomcat to 20 platform threads to make the thread pool ceiling visible at low concurrency. With virtual threads enabled, the Tomcat thread limit is ignored.

| Setting | Platform | Virtual | Reactive |
|---|---|---|---|
| Server | Tomcat (20 threads) | Tomcat (virtual threads) | Netty (event loop) |
| DB driver | JDBC (blocking) | JDBC (blocking) | R2DBC (non-blocking) |
| DB pool | HikariCP, max 20 | HikariCP, max 20 | R2DBC pool, max 20 |
| Simulated I/O | Thread.sleep(50ms) | Thread.sleep(50ms) | Mono.delay(50ms) |
| GC | G1GC | G1GC or ZGC | G1GC |

## Stack

- JDK 26
- Spring Boot 4.0.4
- PostgreSQL 17
- hey (load generator)
