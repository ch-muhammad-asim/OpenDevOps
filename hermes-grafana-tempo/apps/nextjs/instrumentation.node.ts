// OpenTelemetry setup for nextjs-web (Node.js runtime only).
// @vercel/otel builds the tracer provider, the W3C propagator, the fetch
// instrumentation and an OTLP exporter from the standard OTEL_* env vars
// (OTEL_EXPORTER_OTLP_ENDPOINT + "/v1/traces", OTEL_EXPORTER_OTLP_PROTOCOL).
import { registerOTel } from '@vercel/otel';
import type { Attributes, Context, Link } from '@opentelemetry/api';
import { SpanKind, trace } from '@opentelemetry/api';
import {
  AlwaysOffSampler,
  AlwaysOnSampler,
  ParentBasedSampler,
  SamplingDecision,
  TraceIdRatioBasedSampler,
  type Sampler,
  type SamplingResult,
} from '@opentelemetry/sdk-trace-base';

// Same names as the OTEL_TRACES_SAMPLER spec; default parentbased_always_on.
function samplerFromEnv(): Sampler {
  const ratio = Number(process.env.OTEL_TRACES_SAMPLER_ARG ?? '1');
  switch (process.env.OTEL_TRACES_SAMPLER) {
    case 'always_on':
      return new AlwaysOnSampler();
    case 'always_off':
      return new AlwaysOffSampler();
    case 'traceidratio':
      return new TraceIdRatioBasedSampler(ratio);
    case 'parentbased_traceidratio':
      return new ParentBasedSampler({ root: new TraceIdRatioBasedSampler(ratio) });
    case 'parentbased_always_off':
      return new ParentBasedSampler({ root: new AlwaysOffSampler() });
    default:
      return new ParentBasedSampler({ root: new AlwaysOnSampler() });
  }
}

// Keeps only traces that start with an inbound HTTP request, minus probes:
// - drops GET /healthz root spans, so kubelet probes add no traces;
// - drops root spans that are not SERVER spans (Next.js start-up work such as
//   "register instrumentation" and "load route module" pre-warming).
// Child spans of a dropped root are dropped too (parent-based sampling).
class RequestOnlySampler implements Sampler {
  constructor(private readonly delegate: Sampler) {}

  shouldSample(
    context: Context,
    traceId: string,
    spanName: string,
    spanKind: SpanKind,
    attributes: Attributes,
    links: Link[],
  ): SamplingResult {
    if (!trace.getSpanContext(context)) {
      const target = String(attributes['http.target'] ?? attributes['url.path'] ?? '');
      const isProbe = target === '/healthz' || target.startsWith('/healthz?');
      if (isProbe || spanKind !== SpanKind.SERVER) {
        return { decision: SamplingDecision.NOT_RECORD };
      }
    }
    return this.delegate.shouldSample(context, traceId, spanName, spanKind, attributes, links);
  }

  toString(): string {
    return `RequestOnlySampler{${this.delegate.toString()}}`;
  }
}

const ordersUrl = process.env.ORDERS_URL;

registerOTel({
  serviceName: 'nextjs-web', // OTEL_SERVICE_NAME overrides this
  // @vercel/otel adds Vercel platform attributes by default; this app does not run on
  // Vercel, so drop the two that are always set. Set your own via OTEL_RESOURCE_ATTRIBUTES.
  attributes: { 'cloud.provider': undefined, 'vercel.runtime': undefined },
  traceSampler: new RequestOnlySampler(samplerFromEnv()),
  instrumentationConfig: {
    fetch: {
      // @vercel/otel only injects `traceparent` into URLs listed here, so calls to
      // nodejs-orders join the same trace.
      propagateContextUrls: ordersUrl ? [ordersUrl] : [],
    },
  },
});
