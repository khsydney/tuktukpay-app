'use strict';
// Datadog tracing, preloaded before the app: `node -r ./dd-init.js server.js` (see Dockerfile).
// The DD_* environment (DD_AGENT_HOST, DD_ENV, DD_SERVICE, DD_VERSION, DD_LOGS_INJECTION ...) comes
// from the Kubernetes manifest or docker-compose.yml.
const tracer = require('dd-trace').init();

// Express: no span per middleware, so trace.getActiveSpan() in a handler is the request
// (service entry) span, the one APM trace metrics and Bits AI SRE read.
tracer.use('express', { middleware: false });

// The app's @opentelemetry/api calls (business attributes on the active span) go to Datadog.
const provider = new tracer.TracerProvider();
provider.register();
