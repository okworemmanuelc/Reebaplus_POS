'use client';

import { useCallback } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useIdleTimeout } from '@/hooks/useIdleTimeout';

// Idle re-lock: signs the Operator out after inactivity, which drops the tab
// back to the sign-in screen (the app renders <Login/> whenever status is
// signed-out). Only armed while signed in.
const IDLE_TIMEOUT_MS = 15 * 60 * 1000; // 15 minutes

export function IdleLock() {
  const { status, signOut } = useSession();

  const onIdle = useCallback(() => {
    void signOut();
  }, [signOut]);

  useIdleTimeout(onIdle, IDLE_TIMEOUT_MS, status === 'signed-in');
  return null;
}
