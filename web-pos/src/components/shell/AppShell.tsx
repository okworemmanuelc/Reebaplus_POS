'use client';

import type { ReactNode } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCan } from '@/components/permissions/Can';
import { PermissionKeys } from '@/lib/permissions';

// The responsive app shell every later slice slots its UI into. It lays out a
// sticky top bar + a left nav rail + a max-width content column, adapting across
// the four breakpoint bands (CSS in globals.css): a single column on phones, a
// rail from tablet up, labelled sidebar on desktop, centred max-width on wide
// screens.
//
// Nav items are permission-gated (hide-don't-block): an Operator only sees the
// sections their role allows. Slice 1 ships the POS section; Inventory and
// Reports are placeholders for #48/#51 but demonstrate the gate now.
export function AppShell({ children }: { children: ReactNode }) {
  const { operator, signOut } = useSession();
  const canInventory =
    useCan(PermissionKeys.stockView) || useCan(PermissionKeys.productsAdd);
  const canReports = useCan(PermissionKeys.reportsView);

  const roleLabel = operator?.role?.name ?? operator?.role?.slug ?? 'Operator';

  return (
    <div className="shell">
      <header className="shell__topbar">
        <div className="shell__brand">
          <span className="shell__brand-dot" />
          <span>Web POS</span>
          {operator?.business && (
            <span className="shell__business">· {operator.business.name}</span>
          )}
        </div>
        <div className="shell__account">
          <div style={{ textAlign: 'right' }}>
            <div className="shell__account-name">
              {operator?.displayName ?? 'Operator'}
            </div>
            <div className="shell__account-role">{roleLabel}</div>
          </div>
          <button className="btn btn--outline" onClick={() => void signOut()}>
            Sign out
          </button>
        </div>
      </header>

      <div className="shell__body">
        <nav className="shell__nav" aria-label="Primary">
          <NavItem icon="🛒" label="POS" active />
          {canInventory && <NavItem icon="📦" label="Inventory" />}
          {canReports && <NavItem icon="📊" label="Reports" />}
        </nav>

        <main className="shell__content">
          <div className="shell__content-inner">{children}</div>
        </main>
      </div>
    </div>
  );
}

function NavItem({
  icon,
  label,
  active = false,
}: {
  icon: string;
  label: string;
  active?: boolean;
}) {
  return (
    <div
      className={`shell__nav-item${active ? ' shell__nav-item--active' : ''}`}
      aria-current={active ? 'page' : undefined}
    >
      <span className="shell__nav-icon" aria-hidden>
        {icon}
      </span>
      <span>{label}</span>
    </div>
  );
}
