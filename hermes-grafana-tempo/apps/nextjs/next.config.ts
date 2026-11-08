import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // Self-contained server (.next/standalone/server.js) for a small runtime image.
  output: 'standalone',
  poweredByHeader: false,
};

export default nextConfig;
