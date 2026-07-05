/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // The Web POS is online-first (ADR 0007): it talks to Supabase live from the
  // browser. There is no server data layer to build against, so the app runs as
  // a client-rendered SPA over the App Router.
};

export default nextConfig;
