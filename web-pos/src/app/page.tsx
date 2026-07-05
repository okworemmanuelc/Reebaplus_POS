'use client';

import { useSession } from '@/components/providers/SessionProvider';
import { LoginForm } from '@/components/auth/LoginForm';
import { AppShell } from '@/components/shell/AppShell';
import { PosScreen } from '@/components/pos/PosScreen';
import { CartProvider } from '@/components/pos/CartProvider';
import { NavProvider, useNav } from '@/components/providers/NavProvider';
import { InventoryScreen } from '@/components/inventory/InventoryScreen';
import { ReportsScreen } from '@/components/reports/ReportsScreen';

// App entry. The signed-in Supabase session is the Operator (ADR 0011): while it
// resolves we show a spinner; signed-out shows the sign-in screen; signed-in
// shows the shell + POS. An idle timeout (IdleLock in the layout) drops a
// signed-in tab back to signed-out, which re-renders the sign-in screen.
export default function Home() {
  const { status, operator, operatorLoading } = useSession();

  if (status === 'loading') {
    return <FullscreenSpinner label="Loading…" />;
  }

  if (status === 'signed-out') {
    return <LoginForm />;
  }

  // Signed in: wait for the first Operator resolution so the shell paints with
  // the business palette, name, role and permissions in place (no flash).
  if (operatorLoading && !operator) {
    return <FullscreenSpinner label="Loading your business…" />;
  }

  if (operator && !operator.businessId) {
    return <NoBusinessNotice />;
  }

  return (
    <NavProvider>
      <CartProvider>
        <AppShell>
          <MainContent />
        </AppShell>
      </CartProvider>
    </NavProvider>
  );
}

// The content area renders the active view (sidebar-driven, NavProvider). The
// cart lives above this so it survives switching to Inventory and back.
function MainContent() {
  const { view } = useNav();
  if (view === 'inventory') return <InventoryScreen />;
  if (view === 'reports') return <ReportsScreen />;
  return <PosScreen />;
}

function FullscreenSpinner({ label }: { label: string }) {
  return (
    <div className="center-screen">
      <div style={{ display: 'grid', placeItems: 'center', gap: 16 }}>
        <div className="spinner" />
        <p className="muted">{label}</p>
      </div>
    </div>
  );
}

function NoBusinessNotice() {
  const { signOut } = useSession();
  return (
    <div className="center-screen">
      <div className="card" style={{ maxWidth: 420, padding: 28 }}>
        <h2 style={{ marginTop: 0 }}>No business found</h2>
        <p className="muted">
          This account isn&apos;t linked to a business yet. Finish onboarding on
          the mobile app, then sign in here again.
        </p>
        <button
          className="btn btn--outline btn--block"
          onClick={() => void signOut()}
        >
          Sign out
        </button>
      </div>
    </div>
  );
}
