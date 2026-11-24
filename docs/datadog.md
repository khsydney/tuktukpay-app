# TukTukPay with Datadog (branch `tuktukpay-app-with-DD`)

This branch sends everything to **Datadog only**, with Datadog's own tracers and the Datadog Agent, so Datadog sees
TukTukPay the way it sees a native Datadog customer. The goal is a fair test of **Bits AI SRE** (Datadog's
investigation agent, also called Bits Investigation). The OpenTelemetry + Splunk version stays on `main`.

## Why native Datadog tracers, and not OpenTelemetry into Datadog

* Bits AI SRE investigates data that is in Datadog: metrics, APM traces, logs, events, Change Tracking, Watchdog,
  Error Tracking, Database Monitoring and Continuous Profiler ([Investigate issues](https://docs.datadoghq.com/bits_ai/bits_investigation/investigate_issues.md)).
  Datadog's compatibility table shows that apps instrumented with upstream OpenTelemetry SDKs lose Continuous
  Profiler and Data Streams Monitoring and get only partial Database Monitoring
  ([OpenTelemetry compatibility](https://docs.datadoghq.com/opentelemetry/compatibility/)). With the Datadog tracers
  Bits has the same evidence it would have at a Datadog customer.
* **One tracer per process.** Datadog: "Run one SDK per application process." The Splunk/OpenTelemetry agent and a
  Datadog tracer cannot both run inside one service, which is why this is a separate branch, not a switch.
* The **Datadog Agent** is needed anyway: Kubernetes state, container metrics, live processes, container logs and the
  deployments behind Change Tracking all come from it.

The application code did **not** change its API: the services keep calling the OpenTelemetry API for business spans,
attributes and the `tuktukpay.*` metrics, and the Datadog tracers implement that API
([OpenTelemetry API support](https://docs.datadoghq.com/opentelemetry/instrument/api_support/)):
`DD_TRACE_OTEL_ENABLED=true` turns those spans into Datadog spans, `DD_METRICS_OTEL_ENABLED=true` sends the metrics
over OTLP/HTTP to the Agent (port 4318).

## What each service runs

| Service(s) | Tracer | How it is loaded | Notes |
|---|---|---|---|
| risk-engine, merchant-copilot, webhook-dispatcher (+ merchant-sim), wallet-sim, shopping-agent, loadgen | `ddtrace==4.17.2` | `ddtrace-run …` in the Dockerfile `CMD` (and the manifest `command` where one is set) | `opentelemetry-sdk` + `opentelemetry-exporter-otlp` 1.45.2 for the metrics bridge |
| acquirer-sim, ledger | `dd-trace@6.26.0` | `node -r ./dd-init.js server.js`; `dd-init.js` registers the OpenTelemetry `TracerProvider` and turns off per-middleware Express spans | pino logs get `dd.*` fields from `DD_LOGS_INJECTION` |
| payment-router | `dd-java-agent 1.69.1` | `JAVA_TOOL_OPTIONS=-javaagent:/dd/dd-java-agent.jar -Ddd.trace.otel.enabled=true` | The Datadog agent has no instrumentation for the JDK `HttpServer`, so `RouterServer.traced()` opens the server span through the OpenTelemetry API and copies the routing headers (`payment.acquirer`, `route.*`, `payment.card.bin`) onto it |
| checkout-api | `dd-trace-go v2.12.0` (Go 1.26) | in code: `otel.go` installs dd-trace-go's OpenTelemetry `TracerProvider` and `MeterProvider`, and the profiler | `otelhttp` and `redisotel` keep working on top of it |
| chaos-controller | — | not instrumented (war-room tooling) | |

Every service also gets `DD_SERVICE`, `DD_ENV` (= `DEPLOYMENT_ENVIRONMENT`), `DD_VERSION` (= `SERVICE_VERSION`),
`DD_LOGS_INJECTION`, `DD_RUNTIME_METRICS_ENABLED`, `DD_PROFILING_ENABLED` (default on) and
`DD_TRACE_PROPAGATION_STYLE=datadog,tracecontext,baggage`, plus the unified service tagging labels
(`tags.datadoghq.com/env|service|version` on Kubernetes, `com.datadoghq.tags.*` on Compose).

Logs stay one JSON line per event on stdout (see [log-schema.md](log-schema.md)); each line inside a span carries
`dd.trace_id` / `dd.span_id`, and the Agent collects container stdout, so logs link to traces.

## Set up

1. **`.env`** (git-ignored; start from `.env.example`):

   ```dotenv
   DD_API_KEY=<API key>                 # Organization Settings > API Keys
   DD_SITE=datadoghq.com                # your org's site: us3/us5.datadoghq.com, datadoghq.eu, ap1/ap2.datadoghq.com ...
   DEPLOYMENT_ENVIRONMENT=tuktukpay-dd  # the env tag
   # DD_APP_KEY=<application key>       # only for make monitors-apply
   ```

2. **Run the stack**, one of:

   ```bash
   make k8s-up        # kind: cluster, images, Datadog Agent (k8s/datadog-agent.sh), deploy
   make eks-up        # EKS: same, with EKS_AWS_ACCOUNT in .env
   make up            # Docker Compose: the datadog-agent container + the services (no Kubernetes acts)
   ```

3. **Check the Agent receives data:** `make k8s-agent-status` (Compose: `make agent-status`) — the APM section counts
   traces received, the Logs Agent section shows the containers, the OTLP section shows the receiver on.

4. **In Datadog:** APM → Services (`env:<your env>`), the service map, a `POST /v1/payments` trace with its Logs tab,
   Infrastructure → Kubernetes, Logs (`kube_namespace:tuktukpay`), Metrics (`tuktukpay.payments.count`).

## Testing Bits AI SRE

1. **Monitors.** Bits investigates a monitor when it goes to **alert**. Supported types include metric, APM metrics
   (not Trace Analytics), logs, integration (Kubernetes) and composite monitors, and each needs to know its service:
   a `service` tag, or a query that filters or groups by service. `datadog/terraform/main.tf` creates one or more per act,
   all tagged `team:tuktukpay`, `env:<env>`, `service:<name>`, `act:<act>`:

   | Act | Monitors |
   |---|---|
   | 1 — acquirer hang | payment-router error rate, checkout-api error rate and p90, log `acquirer.timeout` |
   | 2 — risk model drift | risk-engine p90, log `risk.inference_slow` |
   | 3 — copilot loop | merchant-copilot p90, log `copilot.tool_loop_suspected` |
   | 4 — agents buying | log `mandate.blocked` (checkout-api) |
   | 5 — ledger contention | ledger p90 and error rate, log `webhook.dead_lettered` |
   | 6 — leaky ledger (Kubernetes) | container OOMKilled, by service |
   | 7 — bad rollout (Kubernetes) | container in CrashLoopBackOff, by service |

   ```bash
   make monitors-plan && make monitors-apply     # needs DD_API_KEY + DD_APP_KEY in .env
   ```

   The APM monitors use trace metrics named after the tracer's operation (`trace.fastapi.request.*`,
   `trace.express.request.*`, `trace.http.server.request.*`). After the first traffic, check the names in
   APM → Services → *service* → Resources and adjust `local.op` in `main.tf` if one differs. Thresholds are starting
   points for `BASE_RPS=4`; tune them after a quiet baseline.

2. **Turn on investigations.** In Datadog, Bits AI SRE → settings: enable automatic investigations for these monitors
   (or start one by hand from a monitor alert). Limits to know: one automatic investigation per monitor per 24 hours,
   20 per 15 minutes per org, and only the transition to alert starts one
   ([Integrations and Settings](https://docs.datadoghq.com/bits_ai/bits_ai_sre/configure/)).

3. **Run an act** from the war room (`make act1` … `make act7`), wait for the monitor, open the Bits investigation, and
   compare its conclusion with the act's answer (the act guide at `/act/<act>`, or the smoking-gun log events in
   [log-schema.md](log-schema.md)). Leave 2–3 minutes of baseline between acts so one act's tail does not look like the
   next act's cause; reset with `make reset`.

4. **Optional, for richer investigations:** connect the GitHub integration and tag the telemetry with Git information
   (`DD_GIT_REPOSITORY_URL`, `DD_GIT_COMMIT_SHA`) so Bits can point at code; change `SERVICE_VERSION` on each deploy so
   Change Tracking shows the rollout.

## Known limits on this branch

* The war-room pages and act guides still tell the Splunk story in their text ("Find it in Splunk", Splunk feature names);
  the evidence is in Datadog here.
* `/healthz` traces are dropped by a sampling rule (`DD_TRACE_SAMPLING_RULES`), not excluded, so they still count in
  trace metrics.
* The .NET ledger variant and the Splunk dual-ship option are not on this branch.
* Bits AI SRE is not available on the US1-FED / GovCloud sites; check that your org's site and plan include it.

## Going back to Splunk

`git switch main` — the OpenTelemetry + Splunk Observability Cloud version, unchanged.
