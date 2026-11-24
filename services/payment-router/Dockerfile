# payment-router: plain Java 21 (no framework, no build tool needed) + the Datadog Java
# agent (dd-java-agent) for tracing.
#
# The only compile-time dependency is the OpenTelemetry API: Log.java emits structured
# log records through the Logs API, reads Span.current() for trace ids and opens the server
# span (RouterServer.traced). At runtime the Datadog agent maps those API calls to Datadog
# spans (dd.trace.otel.enabled=true); without the agent they are no-ops.
FROM eclipse-temurin:21-jdk AS build
ARG OTEL_API_VERSION=1.49.0
WORKDIR /src
ADD https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-api/${OTEL_API_VERSION}/opentelemetry-api-${OTEL_API_VERSION}.jar /otel/opentelemetry-api.jar
ADD https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-context/${OTEL_API_VERSION}/opentelemetry-context-${OTEL_API_VERSION}.jar /otel/opentelemetry-context.jar
COPY src ./src
RUN mkdir -p /out && javac -cp /otel/opentelemetry-api.jar:/otel/opentelemetry-context.jar -d /out $(find src -name "*.java") \
 && cd /out && jar cfe /payment-router.jar com.tuktukpay.router.RouterServer .

FROM eclipse-temurin:21-jre
WORKDIR /app
ARG DD_JAVA_AGENT_VERSION=1.69.1
ADD https://repo1.maven.org/maven2/com/datadoghq/dd-java-agent/${DD_JAVA_AGENT_VERSION}/dd-java-agent-${DD_JAVA_AGENT_VERSION}.jar /dd/dd-java-agent.jar
COPY --from=build /otel/opentelemetry-api.jar /otel/opentelemetry-context.jar /otel/
COPY --from=build /payment-router.jar /app/payment-router.jar
RUN chmod 644 /otel/*.jar /dd/dd-java-agent.jar
EXPOSE 8082
# The agent is attached via JAVA_TOOL_OPTIONS (-javaagent:/dd/dd-java-agent.jar) in the
# manifests / docker-compose.yml, so the same image runs with or without instrumentation.
CMD ["java", "-cp", "/app/payment-router.jar:/otel/opentelemetry-api.jar:/otel/opentelemetry-context.jar", "com.tuktukpay.router.RouterServer"]
