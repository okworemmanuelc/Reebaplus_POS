'use client';

import { useState, useEffect, useRef, type ReactNode } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCan } from '@/components/permissions/Can';
import { PermissionKeys } from '@/lib/permissions';
import { useTheme, type UserThemeMode } from '@/components/providers/ThemeProvider';

// The responsive app shell every later slice slots its UI into. It lays out a
// sticky top bar + a left nav rail + a max-width content column, adapting across
// the four breakpoint bands (CSS in globals.css).
//
// Nav items are permission-gated (hide-don't-block): an Operator only sees the
// sections their role allows.
export function AppShell({ children }: { children: ReactNode }) {
  const { operator, signOut } = useSession();
  const { themeMode, setThemeMode } = useTheme();
  const canInventory =
    useCan(PermissionKeys.stockView) || useCan(PermissionKeys.productsAdd);
  const canReports = useCan(PermissionKeys.reportsView);

  const [isCollapsed, setIsCollapsed] = useState(false);
  const [themeDropdownOpen, setThemeDropdownOpen] = useState(false);
  const themeDropdownRef = useRef<HTMLDivElement>(null);

  // Load initial sidebar state
  useEffect(() => {
    const stored = localStorage.getItem('sidebar-collapsed');
    if (stored === 'true') {
      setIsCollapsed(true);
    }
  }, []);

  const toggleSidebar = () => {
    setIsCollapsed((prev) => {
      const next = !prev;
      localStorage.setItem('sidebar-collapsed', String(next));
      return next;
    });
  };

  // Close dropdown on click outside
  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (
        themeDropdownRef.current &&
        !themeDropdownRef.current.contains(event.target as Node)
      ) {
        setThemeDropdownOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const roleLabel = operator?.role?.name ?? operator?.role?.slug ?? 'Operator';

  const themeLabelMap: Record<UserThemeMode, string> = {
    system: '💻 System',
    light: '☀️ Light',
    dark: '🌙 Dark',
  };

  return (
    <div className={`shell${isCollapsed ? ' shell--collapsed' : ''}`}>
      <header className="shell__topbar">
        <div className="shell__brand">
          <button
            className="shell__sidebar-toggle"
            onClick={toggleSidebar}
            aria-label={isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          >
            ☰
          </button>
          <span className="shell__brand-dot" />
          <span className="shell__brand-text">Web POS</span>
          {operator?.business && (
            <span className="shell__business">· {operator.business.name}</span>
          )}
        </div>

        <div className="shell__actions-group">
          {/* Custom Theme Dropdown */}
          <div className="theme-dropdown" ref={themeDropdownRef}>
            <button
              className="theme-dropdown__toggle"
              onClick={() => setThemeDropdownOpen((o) => !o)}
              aria-expanded={themeDropdownOpen}
              aria-haspopup="listbox"
            >
              {themeLabelMap[themeMode]} <span className="theme-dropdown__arrow">▼</span>
            </button>
            {themeDropdownOpen && (
              <div className="theme-dropdown__menu" role="listbox">
                {(['light', 'dark', 'system'] as UserThemeMode[]).map((mode) => (
                  <button
                    key={mode}
                    role="option"
                    aria-selected={themeMode === mode}
                    className={`theme-dropdown__item${
                      themeMode === mode ? ' theme-dropdown__item--active' : ''
                    }`}
                    onClick={() => {
                      setThemeMode(mode);
                      setThemeDropdownOpen(false);
                    }}
                  >
                    {themeLabelMap[mode]}
                  </button>
                ))}
              </div>
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
        </div>
      </header>

      <div className="shell__body">
        <nav className={`shell__nav${isCollapsed ? ' shell__nav--collapsed' : ''}`} aria-label="Primary">
          <NavItem icon="🛒" label="POS" active collapsed={isCollapsed} />
          {canInventory && <NavItem icon="📦" label="Inventory" collapsed={isCollapsed} />}
          {canReports && <NavItem icon="📊" label="Reports" collapsed={isCollapsed} />}
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
  collapsed = false,
}: {
  icon: string;
  label: string;
  active?: boolean;
  collapsed?: boolean;
}) {
  return (
    <div
      className={`shell__nav-item${active ? ' shell__nav-item--active' : ''}${
        collapsed ? ' shell__nav-item--collapsed' : ''
      }`}
      aria-current={active ? 'page' : undefined}
      title={collapsed ? label : undefined}
    >
      <span className="shell__nav-icon" aria-hidden>
        {icon}
      </span>
      <span className="shell__nav-label">{label}</span>
    </div>
  );
}
