'use client';

import { useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';

// Sign-in screen (AC: "sign in via email OTP and via Google"). Two factors over
// the same Supabase session; on success the session becomes the Operator (ADR
// 0011) and the app entry swaps to the shell. No PIN, no "Who's working?" picker
// on web — deliberately (ADR 0011).
type Step = 'enter-email' | 'enter-code';

export function LoginForm() {
  const { supabase } = useSession();
  const [step, setStep] = useState<Step>('enter-email');
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const sendOtp = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setNotice(null);
    setBusy(true);
    try {
      const { error } = await supabase.auth.signInWithOtp({
        email: email.trim(),
        options: { shouldCreateUser: false },
      });
      if (error) throw error;
      setStep('enter-code');
      setNotice(`We sent a 6-digit code to ${email.trim()}.`);
    } catch (err) {
      setError(messageOf(err));
    } finally {
      setBusy(false);
    }
  };

  const verifyOtp = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const { error } = await supabase.auth.verifyOtp({
        email: email.trim(),
        token: code.trim(),
        type: 'email',
      });
      if (error) throw error;
      // onAuthStateChange (SessionProvider) takes over from here.
    } catch (err) {
      setError(messageOf(err));
    } finally {
      setBusy(false);
    }
  };

  const signInWithGoogle = async () => {
    setError(null);
    setBusy(true);
    try {
      const redirectTo = `${window.location.origin}/auth/callback`;
      const { error } = await supabase.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo },
      });
      if (error) throw error;
      // Browser redirects to Google; no further work here.
    } catch (err) {
      setError(messageOf(err));
      setBusy(false);
    }
  };

  return (
    <div className="center-screen">
      <div className="card" style={{ width: '100%', maxWidth: 380, padding: 28 }}>
        <div className="shell__brand" style={{ marginBottom: 6 }}>
          <span className="shell__brand-dot" />
          <span>Reebaplus Web POS</span>
        </div>
        <p className="muted" style={{ marginTop: 0, fontSize: 14 }}>
          Sign in to operate your business.
        </p>

        {error && (
          <div className="banner banner--error" style={{ marginBottom: 14 }}>
            {error}
          </div>
        )}
        {notice && (
          <div className="banner banner--info" style={{ marginBottom: 14 }}>
            {notice}
          </div>
        )}

        {step === 'enter-email' ? (
          <form onSubmit={sendOtp} style={{ display: 'grid', gap: 14 }}>
            <div className="field">
              <label className="field__label" htmlFor="email">
                Email
              </label>
              <input
                id="email"
                className="input"
                type="email"
                autoComplete="email"
                inputMode="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@business.com"
              />
            </div>
            <button
              className="btn btn--primary btn--block"
              type="submit"
              disabled={busy || !email.trim()}
            >
              {busy ? 'Sending…' : 'Email me a code'}
            </button>
          </form>
        ) : (
          <form onSubmit={verifyOtp} style={{ display: 'grid', gap: 14 }}>
            <div className="field">
              <label className="field__label" htmlFor="code">
                6-digit code
              </label>
              <input
                id="code"
                className="input"
                inputMode="numeric"
                autoComplete="one-time-code"
                required
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="123456"
              />
            </div>
            <button
              className="btn btn--primary btn--block"
              type="submit"
              disabled={busy || code.trim().length < 4}
            >
              {busy ? 'Verifying…' : 'Verify & sign in'}
            </button>
            <button
              type="button"
              className="btn btn--outline btn--block"
              onClick={() => {
                setStep('enter-email');
                setCode('');
                setNotice(null);
              }}
              disabled={busy}
            >
              Use a different email
            </button>
          </form>
        )}

        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            margin: '18px 0',
            color: 'var(--subtext)',
            fontSize: 12,
          }}
        >
          <span style={{ flex: 1, height: 1, background: 'var(--border)' }} />
          OR
          <span style={{ flex: 1, height: 1, background: 'var(--border)' }} />
        </div>

        <button
          type="button"
          className="btn btn--outline btn--block"
          onClick={signInWithGoogle}
          disabled={busy}
        >
          Continue with Google
        </button>
      </div>
    </div>
  );
}

function messageOf(err: unknown): string {
  if (err && typeof err === 'object' && 'message' in err) {
    return String((err as { message: unknown }).message);
  }
  return 'Something went wrong. Please try again.';
}
