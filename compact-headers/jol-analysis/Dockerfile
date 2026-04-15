FROM amazoncorretto:26 AS build

RUN yum install -y tar gzip && yum clean all

WORKDIR /build
COPY pom.xml pom.xml
COPY src src
COPY mvnw mvnw
COPY .mvn .mvn

RUN chmod +x mvnw && ./mvnw package -q -DskipTests

FROM amazoncorretto:26

WORKDIR /app
COPY --from=build /build/target/jol-analysis-*.jar jol-analysis.jar

ENTRYPOINT ["java"]
CMD ["-jar", "jol-analysis.jar"]
