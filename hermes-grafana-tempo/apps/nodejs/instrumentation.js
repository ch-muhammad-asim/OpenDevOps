'use strict';
// OpenTelemetry bootstrap, loaded before the app with `node --require ./instrumentation.js`.
//
// This is the stock `@opentelemetry/auto-instrumentations-node/register` script with ONE
// change: the HTTP instrumentation ignores `GET /healthz`, so kubelet probes do not flood
// Tempo. That option (ignoreIncomingRequestHook) is a function, so it cannot be set
// through an environment variable. Everything else (service name, exporter, endpoint,
// protocol, sampler, resource attributes, enabled instrumentations, resource detectors)
// still comes from the standard OTEL_* environment variables.
const { diag, DiagConsoleLogger, DiagLogLevel } = require('@opentelemetry/api');
const { NodeSDK } = require('@opentelemetry/sdk-node');
const {
  getNodeAutoInstrumentations,
  getResourceDetectors,
} = require('@opentelemetry/auto-instrumentations-node');

if (process.env.OTEL_LOG_LEVEL) {
  diag.setLogger(new DiagConsoleLogger(), {
    logLevel: DiagLogLevel[process.env.OTEL_LOG_LEVEL.toUpperCase()] ?? DiagLogLevel.INFO,
  });
}

const sdk = new NodeSDK({
  // OTEL_NODE_ENABLED_INSTRUMENTATIONS picks which of these are active (http,express,undici).
  instrumentations: getNodeAutoInstrumentations({
    '@opentelemetry/instrumentation-http': {
      ignoreIncomingRequestHook: (req) => req.url === '/healthz',
    },
  }),
  // OTEL_NODE_RESOURCE_DETECTORS picks the detectors (default: all).
  resourceDetectors: getResourceDetectors(),
});

sdk.start();

// Flush buffered spans when Kubernetes stops the pod.
process.on('SIGTERM', () => {
  sdk
    .shutdown()
    .catch((err) => console.error('OpenTelemetry shutdown failed', err))
    .finally(() => process.exit(0));
});
