// Public Supabase connection config for the Web POS.
//
// The URL and anon key are client-public, RLS-gated values — the same class of
// value the Flutter app hardcodes in lib/main.dart by design (see the project's
// "anon key is intentional" decision). Baking the defaults here means the app
// builds and runs with zero env setup; NEXT_PUBLIC_* env vars override them when
// pointing at a different Supabase project.

const DEFAULT_SUPABASE_URL = 'https://ewwyofbvfjyqqirrcaou.supabase.co';
const DEFAULT_SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV3d3lvZmJ2Zmp5cXFpcnJjYW91Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM1NzM0MTgsImV4cCI6MjA4OTE0OTQxOH0.McPYfcKMT_h7j9cEE7GiutREcluXo0x2SxdLP0YsP5Q';

export const supabaseUrl =
  process.env.NEXT_PUBLIC_SUPABASE_URL ?? DEFAULT_SUPABASE_URL;

export const supabaseAnonKey =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? DEFAULT_SUPABASE_ANON_KEY;
