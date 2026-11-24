# TukTukPay log schema

Every service emits the same kind of log record: **one JSON object per line on stdout**. The Datadog Agent collects
container stdout (Kubernetes: `logs.containerCollectAll`; Compose: the Docker socket), parses the JSON and tags each
line with the pod's or container's `env`, `service` and `version`. Inside a span the line also carries
`dd.trace_id` / `dd.span_id` (decimal, lower 64 bits of the trace id) next to the OpenTelemetry-style `trace_id` /
`span_id`, so Datadog links it to the trace — the trace's **Logs** tab and Bits AI SRE both read it.

The design goal is that a reader — a person in a war room or an AI root-cause analysis — can go from an alert
to the cause with the log lines alone: every line names the payment, the merchant, the dependency that misbehaved,
how long it took and why. The "smoking gun" line of every storyline act is listed in the catalogue below.

## Record layout

| Part | Content |
|---|---|
| body / `message` | One human-readable sentence with the key identifiers inline: `acquirer acq-kbank timed out after 2504 ms for payment pay_6f7f… (merchant lazada-th, BIN 457173 THB); failing over to acq-uob` |
| severity | `level`: `DEBUG` (off by default), `INFO`, `WARN`, `ERROR` (Python and Java write `WARNING`/`WARN` as their runtime names them). |
| `event` | Dotted event name, the primary search key: `payment.declined`, `acquirer.timeout`, `db.pool.wait`, `config.changed` … |
| resource | `service.name`, `deployment.environment` in the line; the Datadog Agent adds `service`, `env`, `version` from the pod labels `tags.datadoghq.com/*` (Compose: container labels `com.datadoghq.tags.*`). |
| trace context | `trace_id`, `span_id` (OpenTelemetry hex) and `dd.trace_id`, `dd.span_id` (Datadog decimal) — from the active span; absent for background work (pollers, startup). |
| business keys | Same names as the span attributes, so APM facets and log facets agree: `payment.id`, `merchant.id`, `order.id`, `payment.amount`, `payment.currency`, `payment.method`, `payment.channel`, `payment.initiator`, `payment.card.bin`, `payment.card.network`, `payment.wallet.provider`, `payment.acquirer`, `payment.outcome`, `payment.decline_reason`, `acquirer.response_code`, `route.attempts`, `route.failover`, `route.attempt_summary`, `risk.model_version`, `risk.score`, `risk.decision`, `risk.reasons`, `agent.id`, `agent.protocol`, `mandate.verdict`, `mandate.block_reason`, `amp.task_id`, `amp.kya.rating`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.tool.names`, `guardrail.verdict`, `guardrail.rules`, `webhook.attempt`, `db.pool.max`, `db.pool.waiting`, `db.pool.wait_ms` |
| operational keys | `duration_ms`, `peer.service` (the dependency involved: `risk-engine`, `payment-router`, `ledger`, `wallet-sim`, `postgres`, `redis`, an acquirer name…), `http.response.status_code`, `error.type`, `error.message`, `exception.type`, `exception.stacktrace` |
| config changes | `event=config.changed` with `feature_flag.name`, `feature_flag.enabled`, `feature_flag.params` — logged by the service that consumes a flag when the chaos panel flips it. In a real platform this is the deploy / feature-flag / config-change entry that root-cause analysis looks for first. |

PCI: no PAN, no card-holder data, ever. Cards appear as BIN (6 digits) + last4 only. Prompts and model outputs are not
logged (set `COPILOT_CAPTURE_CONTENT=true` to put them on spans for a demo, never in production).

A stdout line from checkout-api:

```json
{"ts":"2026-10-07T01:12:40.512Z","level":"WARN","service.name":"checkout-api","deployment.environment":"tuktukpay-team01",
 "message":"mandate blocked payment pay_9c1e… from agent shopbot.lazada at lazada-th: mandate_over_limit (payment 14270.00 exceeds mandate ceiling 6500.00 THB)",
 "event":"mandate.blocked","payment.id":"pay_9c1e…","merchant.id":"lazada-th","payment.amount":14270,"payment.currency":"THB",
 "payment.initiator":"agent","agent.id":"shopbot.lazada","agent.protocol":"amp/1.0","mandate.verdict":"blocked",
 "mandate.block_reason":"mandate_over_limit","amp.task_id":"task_4f…","amp.kya.rating":"A","payment.outcome":"declined",
 "http.response.status_code":403,"duration_ms":4,"trace_id":"7d8539cb3eb5c7f9924fc32b7ce43bc7","span_id":"d7812b3f7341b236"}
```

In Datadog every key is a log attribute; query it as a facet with `@`, e.g. `@event:acquirer.timeout`,
`@payment.acquirer:acq-kbank`. `service`, `env` and `version` come from the Agent's tags.

## Event catalogue

Levels: `I` info, `W` warn, `E` error, `D` debug (visible only with `LOG_LEVEL=DEBUG`). "Act" marks the storyline
act a line is evidence for; **bold** events are the smoking gun of that act.

### checkout-api (Go)

| event | lvl | when | key fields | act |
|---|---|---|---|---|
| `payment.approved` | I | acquirer approved | acquirer, response code, `route.attempt_summary`, risk fields, `duration_ms` | baseline |
| `payment.declined` | I/W | acquirer declined (I) or risk model declined before authorisation (W) | `payment.decline_reason`, `risk.reasons`, `risk.model_version` | 1, 2, 4 |
| `payment.failed` | E | every acquirer failed | `route.attempt_summary`, `payment.decline_reason` | 1 (failover off) |
| **`mandate.blocked`** | W | an AMP agent's task mandate was refused | `mandate.block_reason`, `mandate.detail`, `agent.id`, `amp.task_id`, `amp.kya.rating`, `peer.service=wallet-sim` for KYA failures | **4, 4b** |
| `mandate.verified` | I | mandate accepted | `amp.task_id`, `amp.kya.rating`, `amp.mandate.use` | 4 |
| `dependency.unavailable` | E | risk-engine or payment-router did not answer (502) | `peer.service`, `error.type`, `error.message` | any outage |
| `ledger.write_failed` / `ledger.write_slow` | E / W | ledger POST failed / took > 500 ms | `peer.service=ledger`, `duration_ms` | 5 |
| `event.publish_failed` | E | Redis stream write failed | `peer.service=redis` | — |
| `payment.rejected` | W | invalid request body (400) | | — |
| `service.started` | I | startup | `peer.services` | — |

### risk-engine (Python)

| event | lvl | when | key fields | act |
|---|---|---|---|---|
| **`risk.inference_slow`** | W | inference over the 50 ms SLO (one line per inference; during Act 2 every v3 inference) | `risk.inference_ms`, `risk.inference_slo_ms`, `risk.model_version=v3`, `risk.canary_pct`, decision, reasons | **2** |
| `risk.canary_inference` | I | the canary scored a payment within the SLO | `risk.model_version`, `risk.inference_ms`, `risk.canary_pct` | 2 |
| `risk.declined` | W | decision `deny` | `risk.reasons` (e.g. `wallet_geo_risk_v3`, `bot_like_pattern`), `payment.initiator` | 2, 4 |
| `risk.review` | I | decision `review` | | — |
| `risk.scored` | D | decision `allow` | | — |
| **`config.changed`** | I | `risk_model_drift` flipped | `feature_flag.name`, `feature_flag.params` (`canary_pct`, `model_version`, `cpu_work`) | **2** |

### payment-router (Java)

| event | lvl | when | key fields | act |
|---|---|---|---|---|
| **`acquirer.timeout`** | W | an acquirer exceeded the 2.5 s timeout | `payment.acquirer`, `acquirer.timeout_ms`, `duration_ms`, `payment.card.bin`, `payment.currency`, `route.backup_acquirer`, `route.failover` | **1** |
| `route.failover` | W | retryable response (91/96/error), trying the backup | `acquirer.response_code`, `route.backup_acquirer` | 1 |
| `acquirer.error` | E | transport error talking to an acquirer | `error.type`, `error.message` | — |
| `route.authorised` / `route.declined` | I | final outcome | `payment.acquirer`, `acquirer.response_code`, `route.attempts`, `route.attempt_summary` | baseline, 1 |
| `route.failed` | E | all acquirers failed (502) | `route.attempt_summary` | 1 (failover off) |
| `config.changed` | I | `router_failover_disabled` flipped | | 1 |

### acquirer-sim (Node.js)

| event | lvl | when | key fields | act |
|---|---|---|---|---|
| **`acquirer.host_unresponsive`** | W | the KBank host hangs for one BIN range | `acquirer.name`, `payment.card.bin`, `acquirer.hang_ms`, `acquirer.host`, `error.type=issuer_link_degraded` | **1** |
| `acquirer.late_response` | W | the hung request finally answers (router already failed over) | `duration_ms`, `acquirer.late` | 1 |
| `acquirer.authorised` / `acquirer.declined` | I | per authorisation | `acquirer.response_code` (ISO 8583 style: 00, 05, 51, 91…), `acquirer.decline_reason`, `acquirer.cross_border`, `duration_ms` | baseline, 1 |
| `config.changed` | I | `acquirer_kbank_timeout` flipped | `feature_flag.params` (`bin_prefix`, `currency`, `hang_ms`) | 1 |

### ledger (Node.js, or .NET with the same events)

| event | lvl | when | key fields | act |
|---|---|---|---|---|
| **`db.pool.wait`** | W | a request waited > 100 ms for a connection | `db.pool.wait_ms`, `db.pool.max`, `db.pool.waiting`, `db.pool.total` | **5** |
| **`db.pool.reconfigured`** | W | pool resized (the `ledger_db_slow` flag) | `db.pool.max`, `db.pool.previous_max` | **5** |
| `ledger.write_slow` | W | INSERT transaction > 500 ms | `duration_ms`, `db.pool.wait_ms` | 5 |
| `ledger.write_failed` / `db.connect_failed` / `ledger.query_failed` | E | database errors | `error.type` (Postgres code), `error.message`, `peer.service=postgres` | — |
| `ledger.entry_recorded` | D | healthy write | | — |
| **`memory.pressure`** | W/E | every 5 s while `ledger_memory_leak` is on (E above 80% of the container limit) | `process.memory.rss_mb`, `memory.leaked_mb`, `container.memory.limit_mb`, `container.memory.utilization_pct`, `error.type` | **6** (Kubernetes) |
| `memory.released` | I | the leak flag was switched off | | 6 |
| `config.changed` | I | `ledger_db_slow` / `ledger_memory_leak` flipped | `sleep_ms`, `pool_size` / `mb_per_second`, `max_mb` | 5, 6 |

### webhook-dispatcher (Python)

| event | lvl | when | key fields | act |
|---|---|---|---|---|
| `webhook.delivery_failed` | W | merchant answered ≥ 300 | `http.response.status_code`, `webhook.attempt`, `webhook.max_attempts`, `merchant.id` | 5 |
| `webhook.delivery_error` | W | transport error / timeout | `error.type`, `duration_ms` | 5 |
| **`webhook.dead_lettered`** | E | retries exhausted, event parked in `payments.events.dlq` | `webhook.attempts`, `merchant.id`, `payment.id` | **5** |
| `webhook.backlog` | W | delivery > 10 s behind the payment stream (at most one line per 30 s) | `messaging.lag_ms` | 5 |
| `webhook.delivered` | I/D | delivered after a retry (I) / first try (D) | `webhook.attempt` | — |
| `redis.unavailable` / `redis.read_failed` / `webhook.processing_failed` | W/E | infrastructure errors | `peer.service=redis` | — |

### merchant-sim (Python)

| event | lvl | when | key fields | act |
|---|---|---|---|---|
| **`merchant.webhook_error`** | E | the merchant's order service "crashes" (500) | `merchant.id`, `peer.service=<merchant>-order-db`, `error.type` | **5** |
| `merchant.webhook_slow` | W | the merchant holds the webhook for `slow_ms` | `duration_ms` | 5 |
| **`catalog.untrusted_listing_served`** | W | a listing whose description addresses AI agents was served | `catalog.sku`, `security.prompt_injection.suspected` | **4** |
| `merchant.webhook_received` | D | healthy delivery | | — |
| `config.changed` | I | `webhook_merchant_flaky` / `catalog_prompt_injection` flipped | | 4, 5 |

### merchant-copilot (Python, LLM agent)

| event | lvl | when | key fields | act |
|---|---|---|---|---|
| `copilot.answered` | I | per question | `gen_ai.request.model`, `copilot.iterations`, `gen_ai.tool.names`, `gen_ai.usage.*`, `copilot.cost_usd`, `duration_ms`, `guardrail.verdict` | baseline, 3 |
| **`copilot.tool_loop_suspected`** | W | ≥ 5 iterations for one question | `copilot.repeated_tool_calls`, `gen_ai.tool.names` | **3** |
| `copilot.max_iterations` | E | the agent gave up | | 3 |
| **`guardrail.prompt_injection_suspected`** | W | the question matched injection patterns | `guardrail.rules`, `security.prompt_injection.suspected` | **3** |
| **`guardrail.action_blocked`** | W | the model tried a blocked tool (`refund_payment`) | `gen_ai.tool.name`, `guardrail.rules` | **3** |
| `copilot.tool_error` / `copilot.llm_error` | W/E | tool or LLM failure | `error.type`, `peer.service` | — |
| `config.changed` | I | `copilot_tool_loop` flipped | `iterations` | 3 |

### shopping-agent and wallet-sim (Python)

| event | lvl | when | key fields | act |
|---|---|---|---|---|
| `agent.step` / `agent.attack_simulated` / `agent.blocked` / `agent.untrusted_content` | I/W | each step of a console run | `agent.task_id`, `agent.id`, `agent.attack_simulation` | 4 |
| `agent.task_failed` | E | a console run crashed | `exception.*` | — |
| `mandate.issued` | I | the wallet issued a task mandate | `amp.task_id`, `agent.id`, `amp.kya.rating`, `amp.mandate.max_amount`, `amp.mandate.merchants`, `amp.mandate.ttl_s` | 4 |
| `mandate.refused` | W | unregistered agent asked for a mandate | `agent.id` | 4 |
| **`kya.registry_unavailable`** | E | Know-Your-Agent lookups fail (503) | `agent.id`, `peer.service=kya-registry-db`, `error.type=RegistryUnavailable` | **4b** |
| `kya.agent_unknown` | W | lookup for an agent nobody registered | | 4 |
| **`service.crashed`** | CRITICAL | `wallet_crash_loop` on: the process exits a few seconds after start (CrashLoopBackOff on Kubernetes) | `error.type=SchemaMigrationError`, `deployment.release`, `process.exit_code` | **7** (Kubernetes) |
| `config.changed` | I | `kya_registry_down` / `wallet_crash_loop` flipped | | 4b, 7 |

### merchant-storefront (load generator)

| event | lvl | when | key fields |
|---|---|---|---|
| `storefront.stats` | I | every 30 s | `storefront.rps`, `storefront.traffic_multiplier`, `storefront.approval_rate_pct`, `storefront.errors`, `storefront.campaign` |
| `storefront.checkout_error` / `storefront.copilot_error` | W | 5xx or transport error from the platform | `http.response.status_code`, `payment.decline_reason`, `peer.service` |
| `storefront.paused` | I | traffic paused from the war-room panel | |
| `config.changed` | I | `festival_spike`, `agent_traffic_surge`, `agent_mandate_violations`, `copilot_prompt_injection`, `traffic_paused` flipped | `feature_flag.params` (`multiplier`, `agent_share`, `rate`…) |

## Search cheat sheet (Datadog Log Explorer)

```
env:tuktukpay-team01 status:(warn OR error)                                   # then group by service, @event
@event:acquirer.timeout                                                       # Act 1 — group by @payment.acquirer, @payment.card.bin
@event:config.changed                                                         # what changed, when (@feature_flag.name, @feature_flag.enabled)
@event:risk.canary_inference                                                  # Act 2 — avg of @risk.inference_ms by @risk.model_version
@event:(copilot.tool_loop_suspected OR guardrail.action_blocked OR guardrail.prompt_injection_suspected)   # Act 3
@event:mandate.blocked                                                        # Act 4 — group by @mandate.block_reason, @agent.id
@event:(kya.registry_unavailable OR mandate.blocked) @mandate.block_reason:mandate_kya_unavailable        # Act 4b
@event:(db.pool.wait OR ledger.write_slow OR merchant.webhook_error OR webhook.dead_lettered)              # Act 5
trace_id:<id>                                                                 # one trace, all services (or open the trace's Logs tab)
```

The level is the `level` attribute (`INFO`, `WARN`, `ERROR`); add a status remapper on `level` in the log pipeline if
you want Datadog's `status` to follow it.

## How each runtime emits logs

| Runtime | Mechanism | Where |
|---|---|---|
| Python (risk-engine, webhook-dispatcher, merchant-sim, merchant-copilot, shopping-agent, wallet-sim, loadgen) | `tuktuk_logging.py` (copied into each service): a JSON stdout formatter that adds `trace_id`/`span_id` and `dd.trace_id`/`dd.span_id`/`dd.service`/`dd.env`/`dd.version` from the active span; `log_event(logger, level, event, message, **fields)` passes the fields as `extra=`, which become JSON keys. `ddtrace-run` also injects its own `dd.*` attributes (`DD_LOGS_INJECTION`); when it does, its values win. | `services/*/tuktuk_logging.py` |
| Go (checkout-api) | `logging.go`: a `slog` `JSONHandler` on stdout; `traceHandler` adds `trace_id`/`span_id` and `dd.trace_id`/`dd.span_id` from the context, the handler attributes add `dd.service`/`dd.env`/`dd.version`. Business fields reuse the span attributes (`kvToSlog`). | `services/checkout-api/logging.go` |
| Java (payment-router) | `Log.java`: writes the JSON line with the span ids and the `dd.*` fields. It also calls the OpenTelemetry Logs API, which stays a no-op unless `DD_LOGS_OTEL_ENABLED=true` (leave it off, or every line arrives twice). | `services/payment-router/src/main/java/com/tuktukpay/router/Log.java` |
| Node.js (acquirer-sim, ledger) | `log.js`: pino to stdout; `dd-trace` injects `dd.trace_id`, `dd.span_id`, `dd.service`, `dd.env`, `dd.version` into every record (`DD_LOGS_INJECTION=true`). | `services/acquirer-sim/log.js`, `services/ledger/log.js` |

`LOG_LEVEL` (per service, default `INFO`) gates both outputs; `DEBUG` adds the per-request healthy events.
