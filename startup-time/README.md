# startup-time

Benchmark for Article 3 of the [Cloud Native Evolution](https://javaisnotdead.com) series:
**"The 30-Second Problem: Why Java Struggled in Serverless"**

Measures startup time across seven JVM optimization steps using
**Spring PetClinic** — the canonical Spring Boot sample application, cloned and built
automatically on first run.

## Two measurement methods

Choose the method that fits your use case:

### Method 1: HTTP probe (`benchmark.sh`)

Measures **wall-clock time from process start to first `HTTP 200`** on `/actuator/health`.

```bash
./scripts/benchmark.sh          # all steps
./scripts/benchmark.sh appcds   # single step
```

| | |
|---|---|
| ✅ **End-to-end realistic** | Includes everything a load balancer or orchestrator would see — JVM init, framework boot, embedded Tomcat bind, and first request handling. |
| ✅ **Matches production health checks** | Kubernetes liveness/readiness probes work the same way. |
| ⚠️ **Adds ~5-15 ms of curl/network overhead** | Each run includes localhost TCP + HTTP latency, which slightly inflates results — especially noticeable on already-fast AOT/native steps. |
| ⚠️ **Sensitive to OS networking quirks** | Firewall prompts, antivirus, or port reuse delays can add jitter. |

### Method 2: Log parsing (`benchmark-log.sh`)

Parses Spring Boot's self-reported **"Started … in X.XXX seconds"** log line.

```bash
./scripts/benchmark-log.sh          # all steps
./scripts/benchmark-log.sh appcds   # single step
```

| | |
|---|---|
| ✅ **Zero network overhead** | No HTTP round-trip — measures pure JVM + framework initialization. |
| ✅ **Lower variance** | Eliminates curl/TCP jitter, results are more stable between runs. |
| ✅ **Ideal for head-to-head comparison** | Best when you want to isolate the effect of a single optimization. |
| ⚠️ **Under-reports real readiness** | Spring declares "Started" before the first HTTP request can actually be served. The gap is small (~5-20 ms) but real. |
| ⚠️ **Native image: different log format** | GraalVM native binaries may emit a slightly different startup message; verify with your version. |

### Which one to pick?

- **Benchmarking for an article or comparing optimization steps** → use `benchmark-log.sh` (less noise)
- **Estimating cold-start latency for Kubernetes / serverless** → use `benchmark.sh` (matches real-world probe)

Both scripts share the same build cache (`.build/`) and produce independent result files (`.cds/<step>.ms` vs `.cds/<step>-log.ms`), so you can run them side by side.

## Number of runs

Default: 10 runs per step, reports median.

```bash
BENCHMARK_RUNS=5 ./scripts/benchmark.sh
BENCHMARK_RUNS=5 ./scripts/benchmark-log.sh
```

## Steps

| Step | What changes |
|------|-------------|
| `baseline` | Fat JAR, no optimizations (`-Xshare:off`) |
| `extracted` | Unpacked JAR (faster classpath scanning, `-Xshare:off`) |
| `cds` | JDK class archive (`-Xshare:on`) — available since Java 5 |
| `appcds` | Application + JDK class archive — available since Java 10 |
| `lazy-init` | AppCDS + Spring lazy bean initialization |
| `aot` | AppCDS + Spring Boot AOT processing |
| `native` | GraalVM Native Image — no JVM |

## Application

**Spring PetClinic** (Spring Boot 4.0, Spring Data JPA, H2, Thymeleaf, Bean Validation,
Caffeine caching, Spring Actuator). Multiple MVC controllers, JPA entities with
relationships, form validation — representative of a real-world Spring application.
Loads ~6,000–8,000 classes at startup.

## Build cache

Build artifacts are cached in `.build/` (outside Maven's `target/`), so `mvnw clean` won't
trigger a full rebuild. To force a clean slate:

```bash
rm -rf .build/ .cds/ petclinic/
./scripts/benchmark.sh
```

## Windows / Git Bash

Two extra steps are required to run the benchmark in Git Bash on Windows.
Without them either the native build fails outright or results are inflated and unstable.

### 1. Fix `native-image` invocation

GraalVM on Windows ships `native-image` as a `.cmd` file. Git Bash tries to execute it
as a shell script and fails with `@echo off` errors. Create a symlink (no extension) that
points to the `.cmd` wrapper:

```bash
# Run Git Bash as Administrator, then cd to your GraalVM bin/ folder:
ln -s native-image.cmd native-image
```

Git Bash will now find `native-image` as a plain name and delegate correctly to the `.cmd`.

### 2. Exclude workspace from Windows Defender

Spring Boot at startup opens thousands of small files. Without an exclusion, Defender
scans each one, saturates the CPU, and inflates every measurement — especially the
baseline and extracted steps. Results also grow progressively worse across runs.

Open PowerShell as Administrator:

```powershell
Add-MpPreference -ExclusionPath "C:\path\to\your\workspace"
```

**Without step 1** the native build crashes immediately.
**Without step 2** medians are artificially high and grow with each successive run,
making cross-step comparisons unreliable.
