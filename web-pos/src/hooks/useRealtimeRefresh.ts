'use client';

import { useEffect, useRef, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';

// Web POS Slice 5 (#49) — live consistency via Supabase Realtime. The web is
// online-first (ADR 0007): rather than diff individual change events into local
// state, we subscribe to the operational tables and, on any change, trigger a
// debounced re-pull of the affected read (the same RLS-scoped query Slice 1
// wired). This keeps the reconciliation trivially correct — the screen always
// re-derives from the authoritative cloud rows — while still feeling live.
//
// Reconnect/backfill (AC): a channel that drops and re-subscribes fires onChange
// on re-SUBSCRIBED, and a tab that regains focus/connectivity refreshes too, so a
// dropped socket never leaves the view stale.

export type RealtimeStatus = 'connecting' | 'live' | 'offline';

// One Realtime channel per business, listening to the given tables (all scoped
// to business_id via the filter — matches the RLS the channel authorizes with).
// [onChange] is called (debounced) on any insert/update/delete and on reconnect.
export function useRealtimeRefresh({
  supabase,
  businessId,
  tables,
  onChange,
  debounceMs = 350,
}: {
  supabase: SupabaseClient;
  businessId: string | null;
  tables: string[];
  onChange: () => void;
  debounceMs?: number;
}): RealtimeStatus {
  const [status, setStatus] = useState<RealtimeStatus>('connecting');

  // Keep the latest callback without re-subscribing on every render.
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  // A stable key so the effect only re-runs when the actual table set changes.
  const tablesKey = tables.join(',');

  useEffect(() => {
    if (!businessId) return;

    let debounce: ReturnType<typeof setTimeout> | undefined;
    const fire = () => {
      if (debounce) clearTimeout(debounce);
      debounce = setTimeout(() => onChangeRef.current(), debounceMs);
    };

    // Whether we've been subscribed at least once — a later SUBSCRIBED then
    // means a reconnect, so we backfill by re-pulling.
    let hadConnection = false;

    const channel = supabase.channel(`web-pos:${businessId}`);
    for (const table of tablesKey.split(',')) {
      channel.on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table,
          filter: `business_id=eq.${businessId}`,
        },
        fire,
      );
    }
    channel.subscribe((channelStatus) => {
      if (channelStatus === 'SUBSCRIBED') {
        setStatus('live');
        if (hadConnection) fire(); // reconnect → backfill anything missed
        hadConnection = true;
      } else if (
        channelStatus === 'CHANNEL_ERROR' ||
        channelStatus === 'TIMED_OUT' ||
        channelStatus === 'CLOSED'
      ) {
        setStatus('offline');
      }
    });

    // A tab that regains focus or connectivity re-pulls (covers a socket that
    // dropped while backgrounded / offline).
    const onWake = () => {
      if (document.visibilityState === 'visible') fire();
    };
    window.addEventListener('online', fire);
    document.addEventListener('visibilitychange', onWake);

    return () => {
      if (debounce) clearTimeout(debounce);
      window.removeEventListener('online', fire);
      document.removeEventListener('visibilitychange', onWake);
      void supabase.removeChannel(channel);
    };
  }, [supabase, businessId, tablesKey, debounceMs]);

  return status;
}
