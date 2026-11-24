# Datadog monitors for TukTukPay, one or more per war-room act, so Bits AI SRE has alerts to investigate.
#
# Bits AI SRE investigates a monitor when it goes to ALERT. It supports metric, APM metric, log,
# Kubernetes (integration) and composite monitors, and needs to know the service: every monitor
# here filters on service:<name> or groups by service, and carries service / env / team tags.
#
#   cd datadog/terraform
#   set -a; . ../../.env; set +a                     # DD_API_KEY, DD_APP_KEY, DD_SITE, DEPLOYMENT_ENVIRONMENT
#   terraform init
#   terraform apply -var "environment=$DEPLOYMENT_ENVIRONMENT" -var "dd_site=$DD_SITE"
# (or: make monitors-plan / make monitors-apply)
#
# Thresholds are starting points for the simulated traffic (BASE_RPS=4); tune them after a baseline.
# APM monitors use Datadog trace metrics: trace.<operation>.hits / .errors and the trace.<operation>
# latency distribution. The operation names come from the tracers:
#   Python FastAPI (ddtrace)                  fastapi.request
#   Node Express (dd-trace)                   express.request
#   Go otelhttp + Java manual server span     http.server.request   (OpenTelemetry API on the Datadog tracer)
# Check them in APM > Services > <service> > Resources after the first traffic; change local.op if needed.

terraform {
  required_version = ">= 1.5"
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "4.31.0"
    }
  }
}

variable "dd_site" {
  description = "Datadog site of your org (datadoghq.com, us3.datadoghq.com, datadoghq.eu, ap1.datadoghq.com ...)"
  type        = string
  default     = "datadoghq.com"
}

variable "environment" {
  description = "DEPLOYMENT_ENVIRONMENT / DD_ENV of the stack (env tag)"
  type        = string
  default     = "tuktukpay-team01"
}

variable "namespace" {
  description = "Kubernetes namespace of the stack (for the Kubernetes monitors)"
  type        = string
  default     = "tuktukpay"
}

variable "notify" {
  description = "Notification handles appended to every monitor message, e.g. \"@slack-war-room\" (empty = none)"
  type        = string
  default     = ""
}

# DD_API_KEY and DD_APP_KEY are read from the environment by the provider.
provider "datadog" {
  api_url = "https://api.${var.dd_site}/"
}

locals {
  env = var.environment
  op = {
    "checkout-api"     = "http.server.request"
    "payment-router"   = "http.server.request"
    "risk-engine"      = "fastapi.request"
    "merchant-copilot" = "fastapi.request"
    "wallet-sim"       = "fastapi.request"
    "ledger"           = "express.request"
    "acquirer-sim"     = "express.request"
  }
  base_tags = ["team:tuktukpay", "env:${var.environment}", "managed-by:terraform"]
}

# ---- APM: error rate ---------------------------------------------------------------------------
locals {
  error_rate = {
    "payment-router" = { act = "act1", threshold = 0.10, why = "Acquirer KBank timeouts for one card BIN (Act 1)" }
    "checkout-api"   = { act = "act1", threshold = 0.10, why = "Payments API errors (Acts 1, 4b, 7)" }
    "ledger"         = { act = "act5", threshold = 0.05, why = "Ledger write errors (Acts 5, 6)" }
  }
}

resource "datadog_monitor" "error_rate" {
  for_each = local.error_rate
  name     = "TukTukPay [${local.env}] ${each.key} error rate"
  type     = "query alert"
  query    = "sum(last_5m):sum:trace.${local.op[each.key]}.errors{env:${local.env},service:${each.key}}.as_count() / sum:trace.${local.op[each.key]}.hits{env:${local.env},service:${each.key}}.as_count() > ${each.value.threshold}"
  message  = "${each.value.why}: more than ${each.value.threshold * 100}% of ${each.key} requests failed in the last 5 minutes. ${var.notify}"
  monitor_thresholds {
    critical = each.value.threshold
  }
  require_full_window = false
  notify_no_data      = false
  tags                = concat(local.base_tags, ["service:${each.key}", "act:${each.value.act}"])
}

# ---- APM: p90 latency (seconds) ----------------------------------------------------------------
locals {
  latency = {
    "risk-engine"      = { act = "act2", threshold = 0.25, why = "Risk model v3 canary is slow (Act 2)" }
    "merchant-copilot" = { act = "act3", threshold = 15, why = "Copilot tool-call loop (Act 3)" }
    "ledger"           = { act = "act5", threshold = 0.5, why = "Ledger database pool contention (Act 5)" }
    "checkout-api"     = { act = "act1", threshold = 2.0, why = "Payments API slow end to end (Acts 1, 2, 5)" }
  }
}

resource "datadog_monitor" "latency_p90" {
  for_each = local.latency
  name     = "TukTukPay [${local.env}] ${each.key} p90 latency"
  type     = "query alert"
  query    = "percentile(last_5m):p90:trace.${local.op[each.key]}{env:${local.env},service:${each.key}} > ${each.value.threshold}"
  message  = "${each.value.why}: ${each.key} p90 latency above ${each.value.threshold} s for 5 minutes. ${var.notify}"
  monitor_thresholds {
    critical = each.value.threshold
  }
  require_full_window = false
  notify_no_data      = false
  tags                = concat(local.base_tags, ["service:${each.key}", "act:${each.value.act}"])
}

# ---- Logs: the smoking-gun events of each act (docs/log-schema.md) ----------------------------
locals {
  log_events = {
    "acquirer-timeout"    = { service = "payment-router", event = "acquirer.timeout", act = "act1", threshold = 10, why = "Acquirer timeouts (Act 1)" }
    "risk-inference-slow" = { service = "risk-engine", event = "risk.inference_slow", act = "act2", threshold = 20, why = "Risk inference over its 50 ms SLO (Act 2)" }
    "copilot-tool-loop"   = { service = "merchant-copilot", event = "copilot.tool_loop_suspected", act = "act3", threshold = 1, why = "Copilot stuck in a tool-call loop (Act 3)" }
    "mandate-blocked"     = { service = "checkout-api", event = "mandate.blocked", act = "act4", threshold = 5, why = "AI agent payments blocked by the mandate check (Act 4)" }
    "webhook-dead-letter" = { service = "webhook-dispatcher", event = "webhook.dead_lettered", act = "act5", threshold = 3, why = "Merchant webhooks dead-lettered (Act 5)" }
  }
}

resource "datadog_monitor" "log_event" {
  for_each = local.log_events
  name     = "TukTukPay [${local.env}] ${each.value.service}: ${each.value.event}"
  type     = "log alert"
  query    = "logs(\"service:${each.value.service} env:${local.env} @event:${each.value.event}\").index(\"*\").rollup(\"count\").last(\"5m\") > ${each.value.threshold}"
  message  = "${each.value.why}: more than ${each.value.threshold} `${each.value.event}` log lines from ${each.value.service} in 5 minutes. ${var.notify}"
  monitor_thresholds {
    critical = each.value.threshold
  }
  notify_no_data = false
  tags           = concat(local.base_tags, ["service:${each.value.service}", "act:${each.value.act}"])
}

# ---- Kubernetes (Acts 6 and 7), grouped by service so Bits knows which one -------------------
resource "datadog_monitor" "k8s_oomkilled" {
  name    = "TukTukPay [${local.env}] container OOMKilled"
  type    = "query alert"
  query   = "max(last_10m):max:kubernetes_state.container.status_report.count.terminated{kube_namespace:${var.namespace},env:${local.env},reason:oomkilled} by {service} >= 1"
  message = "A TukTukPay container was OOMKilled (Act 6: ledger memory leak). ${var.notify}"
  monitor_thresholds {
    critical = 1
  }
  require_full_window = false
  notify_no_data      = false
  tags                = concat(local.base_tags, ["act:act6"])
}

resource "datadog_monitor" "k8s_crashloop" {
  name    = "TukTukPay [${local.env}] container in CrashLoopBackOff"
  type    = "query alert"
  query   = "max(last_5m):max:kubernetes_state.container.status_report.count.waiting{kube_namespace:${var.namespace},env:${local.env},reason:crashloopbackoff} by {service} >= 1"
  message = "A TukTukPay container is crash-looping (Act 7: wallet-sim, the agent registry). ${var.notify}"
  monitor_thresholds {
    critical = 1
  }
  require_full_window = false
  notify_no_data      = false
  tags                = concat(local.base_tags, ["act:act7"])
}

output "monitor_ids" {
  value = concat(
    [for m in datadog_monitor.error_rate : m.id],
    [for m in datadog_monitor.latency_p90 : m.id],
    [for m in datadog_monitor.log_event : m.id],
    [datadog_monitor.k8s_oomkilled.id, datadog_monitor.k8s_crashloop.id],
  )
}
