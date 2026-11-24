package main

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"

	ddotel "github.com/DataDog/dd-trace-go/v2/ddtrace/opentelemetry"
	ddmetric "github.com/DataDog/dd-trace-go/v2/ddtrace/opentelemetry/metric"
	ddtracer "github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
	"github.com/DataDog/dd-trace-go/v2/profiler"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
)

// setupOTel keeps the service's OpenTelemetry API code (otelhttp, redisotel, the manual
// spans and the tuktukpay.* metrics in main.go) and points it at Datadog:
//
//   - traces: dd-trace-go's OpenTelemetry TracerProvider. Every span created through the
//     OTel API is a Datadog span, sent to the Datadog Agent (DD_AGENT_HOST:8126).
//   - metrics: dd-trace-go's MeterProvider, which exports the OTel metrics over OTLP to the
//     Datadog Agent (OTEL_EXPORTER_OTLP_ENDPOINT, port 4318). Off unless
//     DD_METRICS_OTEL_ENABLED=true.
//   - logs: stdout JSON only (logging.go); the Datadog Agent collects container logs.
//   - Continuous Profiler when DD_PROFILING_ENABLED=true (Bits AI SRE reads profiles).
//
// Service, env and version come from DD_SERVICE / DD_ENV / DD_VERSION.
func setupOTel(ctx context.Context) (func(context.Context) error, error) {
	if os.Getenv("DD_SERVICE") == "" {
		_ = os.Setenv("DD_SERVICE", serviceName)
	}

	tp := ddotel.NewTracerProvider(ddtracer.WithService(os.Getenv("DD_SERVICE")))
	otel.SetTracerProvider(tp)

	mp, err := ddmetric.NewMeterProviderWithContext(ctx)
	if err != nil {
		_ = tp.Shutdown()
		return nil, err
	}
	otel.SetMeterProvider(mp)

	profiling := strings.EqualFold(os.Getenv("DD_PROFILING_ENABLED"), "true")
	if profiling {
		if err := profiler.Start(profiler.WithService(os.Getenv("DD_SERVICE"))); err != nil {
			fmt.Fprintf(os.Stderr, "datadog profiler not started: %v\n", err)
			profiling = false
		}
	}

	// W3C trace context for otelhttp / the Redis stream messages; dd-trace-go reads and
	// writes the same traceparent, and the x-datadog-* headers as well.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		tolerantTraceContext{}, propagation.Baggage{},
	))

	return func(ctx context.Context) error {
		if profiling {
			profiler.Stop()
		}
		return errors.Join(ddmetric.Shutdown(ctx, mp), tp.Shutdown())
	}, nil
}

// tolerantTraceContext accepts W3C Trace Context Level 2 headers.
//
// Newer OpenTelemetry SDKs (Python 1.3x+, for example) set the "random trace id"
// flag, so traceparent ends in "-03". opentelemetry-go before v1.42.0 rejects any
// version-00 flags value above 0x02 and silently starts a new trace, which breaks
// the agent -> checkout-api link. Until the module can move to v1.42+ (Go 1.25),
// mask the flags down to the sampled bit before delegating to the standard
// propagator. Harmless on newer versions.
type tolerantTraceContext struct{ propagation.TraceContext }

func (t tolerantTraceContext) Extract(ctx context.Context, carrier propagation.TextMapCarrier) context.Context {
	if tp := carrier.Get("traceparent"); tp != "" {
		if parts := strings.Split(tp, "-"); len(parts) == 4 && len(parts[3]) == 2 {
			if b, err := hex.DecodeString(parts[3]); err == nil && len(b) == 1 && b[0] > 2 {
				parts[3] = fmt.Sprintf("%02x", b[0]&0x01)
				carrier = &overrideCarrier{TextMapCarrier: carrier, traceparent: strings.Join(parts, "-")}
			}
		}
	}
	return t.TraceContext.Extract(ctx, carrier)
}

type overrideCarrier struct {
	propagation.TextMapCarrier
	traceparent string
}

func (o *overrideCarrier) Get(key string) string {
	if strings.EqualFold(key, "traceparent") {
		return o.traceparent
	}
	return o.TextMapCarrier.Get(key)
}
