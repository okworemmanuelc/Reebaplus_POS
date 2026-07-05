'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCan } from '@/components/permissions/Can';
import { useCurrency } from '@/hooks/useCurrency';
import { PermissionKeys } from '@/lib/permissions';
import {
  loadSalesReport,
  loadActivityLogs,
  type SalesReport,
  type ActivityLogRow,
} from '@/lib/reports';

type Period = 'today' | '7d' | '30d';

const PERIODS: { key: Period; label: string }[] = [
  { key: 'today', label: 'Today' },
  { key: '7d', label: '7 days' },
  { key: '30d', label: '30 days' },
];

function periodStartIso(period: Period): string {
  const now = new Date();
  const d = new Date(now);
  if (period === 'today') {
    d.setHours(0, 0, 0, 0);
  } else if (period === '7d') {
    d.setDate(d.getDate() - 7);
  } else {
    d.setDate(d.getDate() - 30);
  }
  return d.toISOString();
}

const ALL_STORES = 'all';

// Web POS Slice 8 (#51) — read-only reports & dashboards. Sales/revenue KPIs, a
// profit report that excludes Uncosted units transparently (matching mobile),
// activity logs, and store scoping. Cost/profit figures are gated on
// reports.see_profit; the whole screen on reports.see_sales (nav gate).
export function ReportsScreen() {
  const { supabase, operator } = useSession();
  const { kobo } = useCurrency();
  const canSeeProfit = useCan(PermissionKeys.reportsSeeProfit);

  const stores = operator?.stores ?? [];
  const [period, setPeriod] = useState<Period>('7d');
  const [storeId, setStoreId] = useState<string>(ALL_STORES);
  const [report, setReport] = useState<SalesReport | null>(null);
  const [logs, setLogs] = useState<ActivityLogRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const businessId = operator?.businessId ?? null;

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    const scope = storeId === ALL_STORES ? null : storeId;
    try {
      const [r, l] = await Promise.all([
        loadSalesReport(supabase, { fromIso: periodStartIso(period), storeId: scope }),
        loadActivityLogs(supabase, { storeId: scope, limit: 40 }),
      ]);
      setReport(r);
      setLogs(l);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load reports.');
    } finally {
      setLoading(false);
    }
  }, [supabase, period, storeId]);

  useEffect(() => {
    void refresh();
  }, [refresh, businessId]);

  const maxDay = useMemo(
    () => Math.max(1, ...(report?.byDay ?? []).map((d) => d.revenueKobo)),
    [report],
  );

  return (
    <div className="reports">
      <div className="reports__header">
        <h1 className="pos__title">Reports</h1>
        <div className="reports__filters">
          {stores.length > 1 && (
            <select
              className="input reports__store"
              value={storeId}
              onChange={(e) => setStoreId(e.target.value)}
              aria-label="Store scope"
            >
              <option value={ALL_STORES}>All stores</option>
              {stores.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          )}
          <div className="segmented" role="group" aria-label="Period">
            {PERIODS.map((p) => (
              <button
                key={p.key}
                type="button"
                className={`segmented__opt${period === p.key ? ' segmented__opt--active' : ''}`}
                onClick={() => setPeriod(p.key)}
              >
                {p.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      {error && <div className="banner banner--error">{error}</div>}

      {loading && !report ? (
        <div className="empty-state">
          <div className="spinner" style={{ margin: '0 auto 12px' }} />
          Loading reports…
        </div>
      ) : report ? (
        <>
          <div className="stat-grid">
            <StatTile label="Sales revenue" value={kobo(report.revenueKobo)} />
            <StatTile label="Orders" value={report.orderCount.toString()} />
            {canSeeProfit && (
              <>
                <StatTile label="Gross profit" value={kobo(report.grossProfitKobo)} accent />
                <StatTile label="Cost of goods" value={kobo(report.cogsKobo)} />
              </>
            )}
          </div>

          {canSeeProfit && report.uncostedUnits > 0 && (
            <div className="banner banner--info">
              Excludes {report.uncostedUnits} item(s) with no recorded buying price
              from the profit figures.
            </div>
          )}

          {report.byDay.length > 0 && (
            <section className="card reports__panel">
              <h2 className="reports__panel-title">Revenue by day</h2>
              <div className="daybars">
                {report.byDay.map((d) => (
                  <div className="daybars__col" key={d.date} title={`${d.date}: ${kobo(d.revenueKobo)}`}>
                    <div
                      className="daybars__bar"
                      style={{ height: `${Math.round((d.revenueKobo / maxDay) * 100)}%` }}
                    />
                    <span className="daybars__label">{d.date.slice(5)}</span>
                  </div>
                ))}
              </div>
            </section>
          )}

          <section className="card reports__panel">
            <h2 className="reports__panel-title">Top products</h2>
            {report.topProducts.length === 0 ? (
              <p className="muted">No costed sales in this window.</p>
            ) : (
              <div className="inventory__table-wrap">
                <table className="inventory__table">
                  <thead>
                    <tr>
                      <th>Product</th>
                      <th className="num">Qty</th>
                      <th className="num">Revenue</th>
                      {canSeeProfit && <th className="num">Profit</th>}
                    </tr>
                  </thead>
                  <tbody>
                    {report.topProducts.map((p) => (
                      <tr key={p.productId}>
                        <td>{p.name}</td>
                        <td className="num">{p.qty}</td>
                        <td className="num">{kobo(p.revenueKobo)}</td>
                        {canSeeProfit && <td className="num">{kobo(p.profitKobo)}</td>}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          <section className="card reports__panel">
            <h2 className="reports__panel-title">Recent activity</h2>
            {logs.length === 0 ? (
              <p className="muted">No activity yet.</p>
            ) : (
              <ul className="activity-list">
                {logs.map((l) => (
                  <li className="activity-list__item" key={l.id}>
                    <span className="activity-list__desc">{l.description}</span>
                    <span className="activity-list__time">
                      {new Date(l.created_at).toLocaleString()}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      ) : null}
    </div>
  );
}

function StatTile({
  label,
  value,
  accent = false,
}: {
  label: string;
  value: string;
  accent?: boolean;
}) {
  return (
    <div className={`stat-tile${accent ? ' stat-tile--accent' : ''}`}>
      <span className="stat-tile__label">{label}</span>
      <span className="stat-tile__value">{value}</span>
    </div>
  );
}
