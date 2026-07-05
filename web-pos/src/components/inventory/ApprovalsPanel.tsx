'use client';

import { useCallback, useEffect, useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import {
  approveStockAdjustment,
  loadPendingAdjustments,
  type PendingAdjustmentRow,
} from '@/lib/stockAdjustments';

// The manager/CEO approval queue for pending stock adjustments. Approving applies
// the delta server-side; rejecting closes it with no change. Rendered only for an
// operator whose role can approve; the RPC re-checks server-side regardless.
export function ApprovalsPanel({
  nameById,
  onChanged,
}: {
  nameById: Map<string, string>;
  onChanged: () => void;
}) {
  const { supabase, operator } = useSession();
  const [rows, setRows] = useState<PendingAdjustmentRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const businessId = operator?.businessId ?? null;

  const refresh = useCallback(async () => {
    setError(null);
    try {
      setRows(await loadPendingAdjustments(supabase));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load requests.');
    }
  }, [supabase]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const act = useCallback(
    async (id: string, approve: boolean) => {
      if (!businessId) return;
      setBusyId(id);
      setError(null);
      try {
        await approveStockAdjustment(supabase, { businessId, requestId: id, approve });
        await refresh();
        onChanged();
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Action failed.');
      } finally {
        setBusyId(null);
      }
    },
    [supabase, businessId, refresh, onChanged],
  );

  if (rows == null) return null;
  if (rows.length === 0 && !error) return null;

  return (
    <section className="approvals" aria-label="Pending stock adjustments">
      <h2 className="approvals__title">
        Pending approvals <span className="approvals__count">{rows.length}</span>
      </h2>
      {error && <div className="banner banner--error">{error}</div>}
      <div className="approvals__list">
        {rows.map((r) => {
          const add = r.quantity_diff > 0;
          return (
            <div key={r.id} className="approvals__item">
              <div className="approvals__info">
                <span className="inventory__name">
                  {nameById.get(r.product_id) ?? 'Product'}
                </span>
                <span className={`approvals__delta${add ? '' : ' approvals__delta--remove'}`}>
                  {add ? '+' : ''}
                  {r.quantity_diff}
                </span>
                <span className="muted">{r.reason}</span>
              </div>
              <div className="approvals__actions">
                <button
                  className="btn btn--outline btn--sm"
                  disabled={busyId === r.id}
                  onClick={() => void act(r.id, false)}
                >
                  Reject
                </button>
                <button
                  className="btn btn--primary btn--sm"
                  disabled={busyId === r.id}
                  onClick={() => void act(r.id, true)}
                >
                  Approve
                </button>
              </div>
            </div>
          );
        })}
      </div>
    </section>
  );
}
