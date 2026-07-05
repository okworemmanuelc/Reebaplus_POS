'use client';

import { useMemo, useState } from 'react';

import { useCurrency } from '@/hooks/useCurrency';
import type { CustomerWithBalance } from '@/lib/types';

// A searchable modal for attaching a registered customer to the cart (Slice 3,
// user story #12). Each row shows the customer's live derived wallet balance —
// positive (credit we hold) in green, negative (they owe us) in red — so the
// operator can see credit standing before choosing a credit path at checkout.
// Registering a NEW customer is a mobile flow for now (out of scope for Slice 3).
export function CustomerPicker({
  customers,
  loading,
  error,
  onPick,
  onClose,
}: {
  customers: CustomerWithBalance[];
  loading: boolean;
  error: string | null;
  onPick: (customer: CustomerWithBalance) => void;
  onClose: () => void;
}) {
  const { kobo } = useCurrency();
  const [query, setQuery] = useState('');

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return customers;
    return customers.filter(
      (c) =>
        c.name.toLowerCase().includes(q) ||
        (c.phone ?? '').toLowerCase().includes(q),
    );
  }, [customers, query]);

  return (
    <div
      className="modal-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="Attach customer"
    >
      <div className="modal">
        <div className="modal__head">
          <h2 className="modal__title">Attach a customer</h2>
          <button className="modal__close" onClick={onClose} aria-label="Close">
            ✕
          </button>
        </div>

        <div className="modal__body">
          <input
            className="input"
            type="search"
            placeholder="Search by name or phone…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            autoFocus
            aria-label="Search customers"
          />

          {error && <div className="banner banner--error">{error}</div>}

          {loading ? (
            <div className="empty-state">
              <div className="spinner" style={{ margin: '0 auto 12px' }} />
              Loading customers…
            </div>
          ) : filtered.length === 0 ? (
            <div className="empty-state">
              {customers.length === 0
                ? 'No registered customers yet. Add one on the mobile app.'
                : 'No customers match your search.'}
            </div>
          ) : (
            <ul className="customer-list">
              {filtered.map((c) => {
                const owes = c.balanceKobo < 0;
                return (
                  <li key={c.id}>
                    <button
                      type="button"
                      className="customer-list__row"
                      onClick={() => onPick(c)}
                    >
                      <span className="customer-list__info">
                        <span className="customer-list__name">{c.name}</span>
                        {c.phone && (
                          <span className="customer-list__phone">{c.phone}</span>
                        )}
                      </span>
                      <span
                        className={`customer-list__balance${
                          owes
                            ? ' customer-list__balance--owed'
                            : ' customer-list__balance--credit'
                        }`}
                      >
                        {owes
                          ? `Owes ${kobo(-c.balanceKobo)}`
                          : `${kobo(c.balanceKobo)} credit`}
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        <div className="modal__foot">
          <button className="btn btn--outline" onClick={onClose}>
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}
