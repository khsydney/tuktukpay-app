package main

import (
	"context"
	"encoding/binary"
	"log/slog"
	"os"
	"strconv"
	"strings"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

// newLogger builds the service logger (docs/log-schema.md): every record goes to stdout
// as one JSON line, with trace_id / span_id copied from the request context and the
// Datadog correlation fields (dd.trace_id, dd.span_id, dd.service, dd.env, dd.version).
// The Datadog Agent collects container stdout, so each line links to its trace.
func newLogger() *slog.Logger {
	level := parseLevel(os.Getenv("LOG_LEVEL"))
	stdout := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level, ReplaceAttr: renameStdKeys}).
		WithAttrs([]slog.Attr{
			slog.String("service.name", serviceName),
			slog.String("deployment.environment", resourceAttr("deployment.environment")),
			slog.String("dd.service", envOr("DD_SERVICE", serviceName)),
			slog.String("dd.env", envOr("DD_ENV", resourceAttr("deployment.environment"))),
			slog.String("dd.version", os.Getenv("DD_VERSION")),
		})
	return slog.New(&fanoutHandler{
		level:    level,
		handlers: []slog.Handler{&traceHandler{Handler: stdout}},
	})
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func parseLevel(s string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

// resourceAttr reads one key out of OTEL_RESOURCE_ATTRIBUTES (k=v,k=v).
func resourceAttr(key string) string {
	for _, pair := range strings.Split(os.Getenv("OTEL_RESOURCE_ATTRIBUTES"), ",") {
		if k, v, ok := strings.Cut(pair, "="); ok && strings.TrimSpace(k) == key {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func renameStdKeys(groups []string, a slog.Attr) slog.Attr {
	if len(groups) == 0 {
		switch a.Key {
		case slog.TimeKey:
			a.Key = "ts"
		case slog.MessageKey:
			a.Key = "message"
		}
	}
	return a
}

// kvToSlog reuses the span's business attributes as log fields, so Tag Spotlight
// and Log Observer agree on names and values.
func kvToSlog(attrs []attribute.KeyValue) []slog.Attr {
	out := make([]slog.Attr, 0, len(attrs))
	for _, kv := range attrs {
		key := string(kv.Key)
		switch kv.Value.Type() {
		case attribute.STRING:
			out = append(out, slog.String(key, kv.Value.AsString()))
		case attribute.INT64:
			out = append(out, slog.Int64(key, kv.Value.AsInt64()))
		case attribute.FLOAT64:
			out = append(out, slog.Float64(key, kv.Value.AsFloat64()))
		case attribute.BOOL:
			out = append(out, slog.Bool(key, kv.Value.AsBool()))
		case attribute.STRINGSLICE:
			out = append(out, slog.Any(key, kv.Value.AsStringSlice()))
		default:
			out = append(out, slog.String(key, kv.Value.Emit()))
		}
	}
	return out
}

// traceHandler adds trace_id / span_id (OpenTelemetry hex) and dd.trace_id / dd.span_id
// (Datadog decimal, lower 64 bits of the trace id) to the stdout line.
type traceHandler struct{ slog.Handler }

func (h *traceHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		tid, sid := sc.TraceID(), sc.SpanID()
		r = r.Clone()
		r.AddAttrs(slog.String("trace_id", tid.String()), slog.String("span_id", sid.String()),
			slog.String("dd.trace_id", strconv.FormatUint(binary.BigEndian.Uint64(tid[8:]), 10)),
			slog.String("dd.span_id", strconv.FormatUint(binary.BigEndian.Uint64(sid[:]), 10)))
	}
	return h.Handler.Handle(ctx, r)
}

func (h *traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &traceHandler{Handler: h.Handler.WithAttrs(attrs)}
}

func (h *traceHandler) WithGroup(name string) slog.Handler {
	return &traceHandler{Handler: h.Handler.WithGroup(name)}
}

// fanoutHandler sends each record to every handler; LOG_LEVEL gates all of them.
type fanoutHandler struct {
	level    slog.Level
	handlers []slog.Handler
}

func (f *fanoutHandler) Enabled(_ context.Context, l slog.Level) bool { return l >= f.level }

func (f *fanoutHandler) Handle(ctx context.Context, r slog.Record) error {
	var err error
	for _, h := range f.handlers {
		if e := h.Handle(ctx, r.Clone()); e != nil {
			err = e
		}
	}
	return err
}

func (f *fanoutHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	hs := make([]slog.Handler, len(f.handlers))
	for i, h := range f.handlers {
		hs[i] = h.WithAttrs(attrs)
	}
	return &fanoutHandler{level: f.level, handlers: hs}
}

func (f *fanoutHandler) WithGroup(name string) slog.Handler {
	hs := make([]slog.Handler, len(f.handlers))
	for i, h := range f.handlers {
		hs[i] = h.WithGroup(name)
	}
	return &fanoutHandler{level: f.level, handlers: hs}
}
