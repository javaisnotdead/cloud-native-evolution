# Amazon Corretto 26 — OpenJDK 26 distribution with long-term support.
# eclipse-temurin:26 was not available at the time of writing.
FROM amazoncorretto:26

WORKDIR /app

ENV JAVA_OPTS=""

# JAR is mounted from host at /app/app.jar at runtime.
# Used for both blocking (Spring MVC) and reactive (WebFlux) apps.
CMD ["/bin/sh", "-c", "exec java ${JAVA_OPTS} -jar /app/app.jar"]
