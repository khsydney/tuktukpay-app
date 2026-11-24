'use strict';
// Structured, trace-correlated logging for the Node.js services (docs/log-schema.md).
//
// pino writes one JSON line per event to stdout; the Datadog Agent collects it from the
// container. dd-trace (DD_LOGS_INJECTION=true) adds dd.trace_id / dd.span_id / dd.service /
// dd.env / dd.version to every record, so Datadog links each line to its trace.
//
// Conventions: `event` is a dotted event name (acquirer.timeout, ledger.write_failed);
// business keys use the span attribute names (payment.id, merchant.id, ...); never a
// PAN — BIN + last4 only.
const pino = require('pino');

const resource = Object.fromEntries(
  (process.env.OTEL_RESOURCE_ATTRIBUTES || '')
    .split(',')
    .filter((kv) => kv.includes('='))
    .map((kv) => kv.split('=').map((s) => s.trim())),
);

const logger = pino({
  level: (process.env.LOG_LEVEL || 'info').toLowerCase(),
  messageKey: 'message',
  timestamp: pino.stdTimeFunctions.isoTime,
  base: {
    'service.name': process.env.OTEL_SERVICE_NAME || 'unknown-service',
    'deployment.environment': resource['deployment.environment'] || '',
  },
});

// event('warn', 'acquirer.timeout', 'human-readable message', { 'payment.id': ... })
function event(level, name, message, fields = {}) {
  logger[level]({ event: name, ...fields }, message);
}

module.exports = { logger, event };
