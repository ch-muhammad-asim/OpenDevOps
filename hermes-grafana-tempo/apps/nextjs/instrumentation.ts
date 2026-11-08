// Next.js calls register() once when the server starts.
// The OTel SDK only runs in the Node.js runtime, so it lives in instrumentation.node.ts.
export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs') {
    await import('./instrumentation.node');
  }
}
