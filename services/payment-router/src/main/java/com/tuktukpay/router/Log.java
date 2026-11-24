package com.tuktukpay.router;

import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.common.AttributesBuilder;
import io.opentelemetry.api.logs.Logger;
import io.opentelemetry.api.logs.Severity;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Structured, trace-correlated logging (docs/log-schema.md).
 *
 * Every event is written as one JSON line on stdout, with trace_id / span_id from the current
 * span and the Datadog correlation fields (dd.trace_id, dd.span_id, dd.service, dd.env,
 * dd.version). The Datadog Agent collects container stdout, so each line links to its trace.
 * The record also goes through the OpenTelemetry Logs API, which is a no-op here unless
 * DD_LOGS_OTEL_ENABLED=true (then the Datadog agent would export it twice - leave it off).
 *
 * Usage: Log.event(Log.Level.WARN, "acquirer.timeout", "acquirer acq-kbank timed out ...",
 *                  "payment.id", id, "payment.acquirer", "acq-kbank", "duration_ms", 2504L);
 */
public final class Log {
    public enum Level { DEBUG, INFO, WARN, ERROR }

    private static final String SERVICE = System.getenv().getOrDefault("OTEL_SERVICE_NAME", "payment-router");
    private static final String ENVIRONMENT = resourceAttr("deployment.environment");
    private static final Level MIN_LEVEL = parseLevel(System.getenv().getOrDefault("LOG_LEVEL", "info"));
    private static volatile Logger otelLogger;

    private Log() {}

    public static void event(Level level, String event, String message, Object... keyValues) {
        if (level.ordinal() < MIN_LEVEL.ordinal()) return;

        Map<String, Object> line = new LinkedHashMap<>();
        line.put("ts", Instant.now().toString());
        line.put("level", level.name());
        line.put("service.name", SERVICE);
        line.put("deployment.environment", ENVIRONMENT);
        line.put("message", message);
        line.put("event", event);
        AttributesBuilder attrs = Attributes.builder().put("event", event);
        for (int i = 0; i + 1 < keyValues.length; i += 2) {
            String key = String.valueOf(keyValues[i]);
            Object value = keyValues[i + 1];
            if (value == null) continue;
            line.put(key, value);
            if (value instanceof Boolean) attrs.put(key, (Boolean) value);
            else if (value instanceof Integer || value instanceof Long) attrs.put(key, ((Number) value).longValue());
            else if (value instanceof Number) attrs.put(key, ((Number) value).doubleValue());
            else attrs.put(key, String.valueOf(value));
        }
        SpanContext span = Span.current().getSpanContext();
        if (span.isValid()) {
            line.put("trace_id", span.getTraceId());
            line.put("span_id", span.getSpanId());
            // Datadog log-trace correlation: decimal ids, lower 64 bits of the trace id.
            line.put("dd.trace_id", Long.toUnsignedString(Long.parseUnsignedLong(span.getTraceId().substring(16), 16)));
            line.put("dd.span_id", Long.toUnsignedString(Long.parseUnsignedLong(span.getSpanId(), 16)));
        }
        line.put("dd.service", System.getenv().getOrDefault("DD_SERVICE", SERVICE));
        line.put("dd.env", System.getenv().getOrDefault("DD_ENV", ENVIRONMENT));
        line.put("dd.version", System.getenv().getOrDefault("DD_VERSION", ""));
        System.out.println(Json.write(line));

        otel().logRecordBuilder()
                .setSeverity(severity(level))
                .setSeverityText(level.name())
                .setBody(message)
                .setAllAttributes(attrs.build())
                .emit();
    }

    private static Logger otel() {
        Logger logger = otelLogger;
        if (logger == null) {
            logger = GlobalOpenTelemetry.get().getLogsBridge().get("tuktukpay.payment-router");
            otelLogger = logger;
        }
        return logger;
    }

    private static Severity severity(Level level) {
        switch (level) {
            case DEBUG: return Severity.DEBUG;
            case WARN: return Severity.WARN;
            case ERROR: return Severity.ERROR;
            default: return Severity.INFO;
        }
    }

    private static Level parseLevel(String s) {
        switch (s.trim().toLowerCase()) {
            case "debug": return Level.DEBUG;
            case "warn":
            case "warning": return Level.WARN;
            case "error": return Level.ERROR;
            default: return Level.INFO;
        }
    }

    /** One key out of OTEL_RESOURCE_ATTRIBUTES (k=v,k=v). */
    private static String resourceAttr(String key) {
        for (String pair : System.getenv().getOrDefault("OTEL_RESOURCE_ATTRIBUTES", "").split(",")) {
            int eq = pair.indexOf('=');
            if (eq > 0 && pair.substring(0, eq).trim().equals(key)) return pair.substring(eq + 1).trim();
        }
        return "";
    }
}
