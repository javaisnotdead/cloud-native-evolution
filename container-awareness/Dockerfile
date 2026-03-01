# =============================================================================
# Build stage — compile once, run on 4 different JVMs
# =============================================================================
FROM maven:3.9-eclipse-temurin-17 AS builder

WORKDIR /app
COPY app/pom.xml .
COPY app/src ./src
RUN mvn package -q -DskipTests --no-transfer-progress


# =============================================================================
# java8-legacy — Java 8 without container support (simulates pre-8u131)
# UseContainerSupport explicitly disabled to demonstrate legacy behavior
#
# DISCLAIMER: In a real 2016 scenario, this would be an unpatched Java 8u121 
# image. We use a modern secure image and explicitly disable container support 
# to artificially regress the engine for demonstration purposes safely.
# =============================================================================
FROM eclipse-temurin:8-jre AS java8-legacy

WORKDIR /app
COPY --from=builder /app/target/container-demo.jar .
CMD ["java", "-XX:-UseContainerSupport", "-jar", "container-demo.jar"]


# =============================================================================
# java8-fixed — Java 8u191+ with container support enabled
# Requires explicit flags: UseContainerSupport + MaxRAMPercentage
# =============================================================================
FROM eclipse-temurin:8-jre AS java8-fixed

WORKDIR /app
COPY --from=builder /app/target/container-demo.jar .
CMD ["java", \
     "-XX:+UseContainerSupport", \
     "-XX:MaxRAMPercentage=75.0", \
     "-jar", "container-demo.jar"]


# =============================================================================
# java11 — Container support automatic, no flags needed
# G1GC container-aware, memory returned to OS (JEP 346)
# =============================================================================
FROM eclipse-temurin:11-jre AS java11

WORKDIR /app
COPY --from=builder /app/target/container-demo.jar .
CMD ["java", \
     "-XX:MaxRAMPercentage=75.0", \
     "-jar", "container-demo.jar"]


# =============================================================================
# java17 — Full cgroups v1 + v2 support, production standard
# =============================================================================
FROM eclipse-temurin:17-jre AS java17

WORKDIR /app
COPY --from=builder /app/target/container-demo.jar .
CMD ["java", \
     "-XX:MaxRAMPercentage=75.0", \
     "-jar", "container-demo.jar"]
