'use client';

import { useEffect, useRef } from 'react';

// Fires `onIdle` after `timeoutMs` of no user interaction. Any of a small set of
// activity events resets the timer. Used to re-lock the tab to the sign-in
// screen after inactivity (AC: "Idle inactivity re-locks the tab to the sign-in
// screen") on shared computers.
const ACTIVITY_EVENTS: (keyof WindowEventMap)[] = [
  'mousemove',
  'mousedown',
  'keydown',
  'scroll',
  'touchstart',
  'click',
];

export function useIdleTimeout(
  onIdle: () => void,
  timeoutMs: number,
  enabled: boolean,
): void {
  const onIdleRef = useRef(onIdle);
  onIdleRef.current = onIdle;

  useEffect(() => {
    if (!enabled) return;

    let timer: ReturnType<typeof setTimeout>;
    const reset = () => {
      clearTimeout(timer);
      timer = setTimeout(() => onIdleRef.current(), timeoutMs);
    };

    for (const evt of ACTIVITY_EVENTS) {
      window.addEventListener(evt, reset, { passive: true });
    }
    reset();

    return () => {
      clearTimeout(timer);
      for (const evt of ACTIVITY_EVENTS) {
        window.removeEventListener(evt, reset);
      }
    };
  }, [timeoutMs, enabled]);
}
