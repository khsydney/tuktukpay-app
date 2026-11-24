"""Structured, trace-correlated logging for the TukTukPay Python services.

Every service logs the same way (this file is copied verbatim into each Python
service directory, like chaos.py):

  * one JSON line per event on stdout. The Datadog Agent collects container stdout
    (logs.containerCollectAll) and tags it with the pod's env / service / version labels.
  * dd.trace_id / dd.span_id on every line inside a span, so Datadog links the log to the
    APM trace. ddtrace-run also injects these (DD_LOGS_INJECTION); when it does, its values win.

Conventions (docs/log-schema.md):
  event              dotted event name, e.g. payment.declined, acquirer.timeout
  business keys      payment.id, merchant.id, payment.acquirer, risk.model_version ...
  trace_id/span_id   added automatically from the active span (OpenTelemetry hex form)
  dd.trace_id/...    the Datadog correlation fields (decimal, lower 64 bits of the trace id)
  PCI                never a PAN or card-holder data: BIN (6 digits) + last4 only

Usage:
    from tuktuk_logging import setup_logging, log_event
    log = setup_logging("risk-engine")
    log_event(log, logging.WARNING, "risk.declined", "risk model denied payment",
              **{"payment.id": pid, "merchant.id": mid, "risk.model_version": "v3"})
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time

from opentelemetry import trace

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "unknown-service")


def _resource_attr(key: str, default: str = "") -> str:
    for pair in os.getenv("OTEL_RESOURCE_ATTRIBUTES", "").split(","):
        k, _, v = pair.partition("=")
        if k.strip() == key:
            return v.strip()
    return default


DEPLOYMENT_ENVIRONMENT = _resource_attr("deployment.environment", os.getenv("DEPLOYMENT_ENVIRONMENT", ""))

# LogRecord attributes that are not business fields.
_STANDARD_ATTRS = set(logging.LogRecord("x", logging.INFO, "x", 0, "", (), None).__dict__) | {
    "message", "asctime", "taskName", "otelTraceID", "otelSpanID", "otelServiceName", "otelTraceSampled",
}


class JsonFormatter(logging.Formatter):
    """stdout format: one JSON object per line, same keys as the exported record."""

    def format(self, record: logging.LogRecord) -> str:
        out = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)) + f".{int(record.msecs):03d}Z",
            "level": record.levelname,
            "service.name": SERVICE_NAME,
            "deployment.environment": DEPLOYMENT_ENVIRONMENT,
            "logger": record.name,
            "message": record.getMessage(),
        }
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            out["trace_id"] = format(ctx.trace_id, "032x")
            out["span_id"] = format(ctx.span_id, "016x")
            # Datadog log-trace correlation: decimal ids, lower 64 bits of the trace id.
            out["dd.trace_id"] = str(ctx.trace_id & 0xFFFFFFFFFFFFFFFF)
            out["dd.span_id"] = str(ctx.span_id)
        out["dd.service"] = os.getenv("DD_SERVICE", SERVICE_NAME)
        out["dd.env"] = os.getenv("DD_ENV", DEPLOYMENT_ENVIRONMENT)
        out["dd.version"] = os.getenv("DD_VERSION", "")
        for key, value in record.__dict__.items():
            if key not in _STANDARD_ATTRS and not key.startswith("_"):
                out[key] = value
        if record.exc_info and record.exc_info[0] is not None:
            out["exception.type"] = record.exc_info[0].__name__
            out["exception.stacktrace"] = self.formatException(record.exc_info)
        return json.dumps(out, default=str, ensure_ascii=False)


class _ExportFilter(logging.Filter):
    """Keep exporter diagnostics (export retries, queue full...) out of the log stream:
    they would drown the business logs during an agent hiccup."""

    def filter(self, record: logging.LogRecord) -> bool:
        return not record.name.startswith("opentelemetry")


def setup_logging(name: str) -> logging.Logger:
    """Configure the root logger once; returns the service logger."""
    root = logging.getLogger()
    root.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
    for handler in list(root.handlers):
        if type(handler).__name__ == "LoggingHandler":  # an OTLP log handler, if one was attached: keep, but filter
            handler.addFilter(_ExportFilter())
        else:  # basicConfig / ddtrace text handlers: replaced by JSON
            root.removeHandler(handler)
    stdout = logging.StreamHandler(sys.stdout)
    stdout.setFormatter(JsonFormatter())
    root.addHandler(stdout)
    for noisy in ("httpx", "httpcore", "urllib3", "uvicorn.access", "opentelemetry", "ddtrace"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    return logging.getLogger(name)


def log_event(logger: logging.Logger, level: int, event: str, message: str, exc_info=None, **fields) -> None:
    """Emit one structured event. `fields` become log attributes (Datadog log facets)."""
    logger.log(level, message, exc_info=exc_info, extra={"event": event, **fields})
