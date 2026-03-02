# Container Awareness Demo

Code examples for **Cloud Native Evolution - Article 2**:
[When Docker Killed Your Java App (And You Didn't Know Why)](https://www.javaisnotdead.com/jvm-container-awareness-docker-oomkill/)

Demonstrates how Java 8, 8u191, 11, and 17 read container resource limits differently.
One application, four JVM versions, side-by-side comparison via Docker Compose.

## Prerequisites

- Docker
- Docker Compose

## Quick Start

```bash
docker-compose up --build
```

## Scenarios
By default all scenarios are run.
Set the `SCENARIO` environment variable to run a specific scenario:

| Value        | Description                                              |
|--------------|----------------------------------------------------------|
| `detection`  | How JVM detects container boundaries                     |
| `memory`     | Heap allocation across container memory limits           |
| `cpu`        | Thread pool sizing with different CPU limits             |

```bash
# Run memory scenario across all JVM versions
SCENARIO=memory docker-compose up --build
```

## What You'll See

`java8-legacy` reads host memory and CPUs ignoring container limits.
`java8-fixed` reads container limits after explicit flags are set.
`java11` and `java17` detect container limits automatically.

## Project Structure

```
container-awareness/
├── app/
│   ├── pom.xml
│   └── src/main/java/com/javaisnotdead/container/
│       └── ContainerDemo.java
├── Dockerfile              # Multi-stage: builder + 4 runtime targets
├── docker-compose.yml
└── README.md
```
