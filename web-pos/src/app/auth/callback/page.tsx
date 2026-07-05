'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';

import { useSession } from '@/components/providers/SessionProvider';

// OAuth return landing. The browser Supabase client (detectSessionInUrl) parses
// the Google PKCE code from the URL and establishes the session; once the
// session is present we send the Operator to the app root.
export default function AuthCallbackPage() {
  const router = useRouter();
  const { status } = useSession();

  useEffect(() => {
    if (status === 'signed-in') {
      router.replace('/');
    } else if (status === 'signed-out') {
      // No session materialised (e.g. user cancelled) — back to sign-in.
      router.replace('/');
    }
  }, [status, router]);

  return (
    <div className="center-screen">
      <div style={{ display: 'grid', placeItems: 'center', gap: 16 }}>
        <div className="spinner" />
        <p className="muted">Signing you in…</p>
      </div>
    </div>
  );
}
