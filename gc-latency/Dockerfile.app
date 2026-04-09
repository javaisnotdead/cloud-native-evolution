# Eclipse Temurin 25 — OpenJDK 25 LTS distribution.
# Generational ZGC is default since JDK 23; non-generational ZGC was removed in JDK 24.
FROM eclipse-temurin:25-jdk

WORKDIR /app

ENV JAVA_OPTS=""

# JAR is mounted from host at /app/app.jar at runtime.
# GC logs are written to /gc-logs which is volume-mounted by the benchmark script.
CMD ["/bin/sh", "-c", "exec java ${JAVA_OPTS} -jar /app/app.jar"]
