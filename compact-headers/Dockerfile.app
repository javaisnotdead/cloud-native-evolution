# Stage 1: Build
FROM amazoncorretto:26 AS build

RUN yum install -y tar gzip && yum clean all

WORKDIR /build
COPY mvnw mvnw
COPY .mvn .mvn
COPY app/pom.xml app/pom.xml
COPY app/src app/src

RUN chmod +x mvnw && ./mvnw -f app/pom.xml package -q -DskipTests

# Stage 2: Runtime
FROM amazoncorretto:26

WORKDIR /app
COPY --from=build /build/app/target/compact-headers-benchmark-*.jar app.jar

ENV JAVA_OPTS=""

CMD ["/bin/sh", "-c", "exec java ${JAVA_OPTS} -jar /app/app.jar"]
