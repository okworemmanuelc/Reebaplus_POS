'use client';

import { useState, useEffect, useRef, type ReactNode } from 'react';

import { useSession } from '@/components/providers/SessionProvider';
import { useCan } from '@/components/permissions/Can';
import { PermissionKeys } from '@/lib/permissions';
import { useTheme, type UserThemeMode } from '@/components/providers/ThemeProvider';
import { useCart } from '@/components/pos/CartProvider';
import { useNav } from '@/components/providers/NavProvider';

// Outline SVG Icons for Sidebar & Header
const HomeIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="m3 9 9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
    <polyline points="9 22 9 12 15 12 15 22" />
  </svg>
);

const ProductsIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z" />
    <polyline points="3.29 7 12 12 20.71 7" />
    <line x1="12" y1="22" x2="12" y2="12" />
  </svg>
);

const SalesIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <rect width="8" height="4" x="8" y="2" rx="1" ry="1" />
    <path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2" />
    <path d="M9 12h6" />
    <path d="M9 16h6" />
  </svg>
);

const ReportsIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <line x1="18" y1="20" x2="18" y2="10" />
    <line x1="12" y1="20" x2="12" y2="4" />
    <line x1="6" y1="20" x2="6" y2="14" />
  </svg>
);

const SettingsIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <line x1="4" y1="21" x2="4" y2="14" />
    <line x1="4" y1="10" x2="4" y2="3" />
    <line x1="12" y1="21" x2="12" y2="12" />
    <line x1="12" y1="8" x2="12" y2="3" />
    <line x1="20" y1="21" x2="20" y2="16" />
    <line x1="20" y1="12" x2="20" y2="3" />
    <line x1="2" y1="14" x2="6" y2="14" />
    <line x1="10" y1="8" x2="14" y2="8" />
    <line x1="18" y1="16" x2="22" y2="16" />
  </svg>
);

const LogoutIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
    <polyline points="16 17 21 12 16 7" />
    <line x1="21" y1="12" x2="9" y2="12" />
  </svg>
);

const SearchIcon = () => (
  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className="search-bar__icon">
    <circle cx="11" cy="11" r="8" />
    <line x1="21" y1="21" x2="16.65" y2="16.65" />
  </svg>
);

const EyeIcon = () => (
  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" style={{ marginRight: '6px' }}>
    <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z" />
    <circle cx="12" cy="12" r="3" />
  </svg>
);

const SunIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
    <circle cx="12" cy="12" r="4" />
    <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />
  </svg>
);

const MoonIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z" />
  </svg>
);

const LaptopIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
    <rect width="18" height="12" x="3" y="4" rx="2" ry="2" />
    <line x1="2" y1="20" x2="22" y2="20" />
    <line x1="12" y1="16" x2="12" y2="20" />
  </svg>
);

export function AppShell({ children }: { children: ReactNode }) {
  const { operator, signOut } = useSession();
  const { themeMode, setThemeMode } = useTheme();
  const cart = useCart();
  const { view, setView } = useNav();
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

  const themeIconMap: Record<UserThemeMode, ReactNode> = {
    system: <LaptopIcon />,
    light: <SunIcon />,
    dark: <MoonIcon />,
  };

  const themeLabelMap: Record<UserThemeMode, string> = {
    system: 'System',
    light: 'Light',
    dark: 'Dark',
  };

  // Extract first letter of name for placeholder avatar
  const displayName = operator?.displayName ?? 'Okwor Emmanuel';
  const firstLetter = displayName[0].toUpperCase();

  return (
    <div className={`shell${isCollapsed ? ' shell--collapsed' : ''}`}>
      {/* 1. Left Sidebar Navigation (Full Height) */}
      <aside className={`shell__nav${isCollapsed ? ' shell__nav--collapsed' : ''}`} aria-label="Primary">
        {/* Brand Logo at top */}
        <div className="shell__brand">
          <span className="shell__brand-logo">
            R<span className="plus-sign">+</span>
          </span>
        </div>

        {/* Navigation List */}
        <div className="shell__nav-items">
          <NavItem
            icon={<HomeIcon />}
            label="Sell"
            active={view === 'pos'}
            collapsed={isCollapsed}
            onClick={() => setView('pos')}
          />
          {canInventory && (
            <NavItem
              icon={<ProductsIcon />}
              label="Products"
              active={view === 'inventory'}
              collapsed={isCollapsed}
              onClick={() => setView('inventory')}
            />
          )}
          <NavItem icon={<SalesIcon />} label="Sales" collapsed={isCollapsed} />
          {canReports && <NavItem icon={<ReportsIcon />} label="Reports" collapsed={isCollapsed} />}
          <NavItem icon={<SettingsIcon />} label="Settings" collapsed={isCollapsed} />
        </div>

        {/* Sidebar Toggle & Logout at the bottom */}
        <div className="shell__nav-footer">
          <button
            type="button"
            className="shell__sidebar-toggle-btn"
            onClick={toggleSidebar}
            aria-label={isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            title={isCollapsed ? 'Expand' : 'Collapse'}
          >
            {isCollapsed ? '❯' : '❮'}
          </button>
          
          <button
            type="button"
            className="shell__nav-item shell__logout-btn"
            onClick={() => void signOut()}
            title="Sign Out"
          >
            <span className="shell__nav-icon"><LogoutIcon /></span>
            <span className="shell__nav-label">Logout</span>
          </button>
        </div>
      </aside>

      {/* 2. Top Bar (Header) */}
      <header className="shell__topbar">
        {/* Business and Screen Info */}
        <div className="shell__title-area">
          <h1 className="shell__business-title">REEBAPLUS POS</h1>
          <div className="shell__subtitle">
            Point of Sale • {operator?.business?.name ?? 'Ellipse Enterprise'}
          </div>
        </div>

        {/* Actions Group (Search, Views, Profile, Theme) */}
        <div className="shell__actions-group">
          {/* Search bar inside header */}
          <div className="search-bar">
            <SearchIcon />
            <input
              type="text"
              className="search-bar__input"
              placeholder="Search"
              value={cart.searchQuery}
              onChange={(e) => cart.setSearchQuery(e.target.value)}
            />
          </div>

          {/* View Dropdown */}
          <button className="btn btn--outline shell__view-btn" type="button">
            <EyeIcon />
            <span>View</span>
            <span className="dropdown-arrow">▼</span>
          </button>

          {/* Custom Theme Dropdown Icon Toggle */}
          <div className="theme-dropdown" ref={themeDropdownRef}>
            <button
              className="theme-dropdown__icon-toggle"
              onClick={() => setThemeDropdownOpen((o) => !o)}
              aria-expanded={themeDropdownOpen}
              aria-haspopup="listbox"
              aria-label="Change theme"
              title={`Theme: ${themeLabelMap[themeMode]}`}
            >
              {themeIconMap[themeMode]}
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
                    <span className="theme-dropdown__item-icon">{themeIconMap[mode]}</span>
                    <span>{themeLabelMap[mode]}</span>
                  </button>
                ))}
              </div>
            )}
          </div>

          {/* User Profile Chip */}
          <div className="shell__account-profile">
            <div className="shell__avatar-container">
              <div className="shell__avatar-placeholder">
                {firstLetter}
              </div>
              <span className="shell__avatar-status" />
            </div>
            <div className="shell__account-info">
              <div className="shell__account-name">{displayName}</div>
              <div className="shell__account-role">{roleLabel}</div>
            </div>
          </div>

          {/* Simple Sign Out Button */}
          <button className="btn btn--outline shell__signout-btn" onClick={() => void signOut()}>
            Sign Out
          </button>
        </div>
      </header>

      {/* 3. Main Content Container */}
      <main className="shell__content">
        <div className="shell__content-inner">{children}</div>
      </main>
    </div>
  );
}

function NavItem({
  icon,
  label,
  active = false,
  collapsed = false,
  onClick,
}: {
  icon: ReactNode;
  label: string;
  active?: boolean;
  collapsed?: boolean;
  onClick?: () => void;
}) {
  const className = `shell__nav-item${active ? ' shell__nav-item--active' : ''}${
    collapsed ? ' shell__nav-item--collapsed' : ''
  }`;
  const inner = (
    <>
      <span className="shell__nav-icon" aria-hidden>
        {icon}
      </span>
      <span className="shell__nav-label">{label}</span>
    </>
  );

  // Interactive items are real buttons (keyboard + a11y); inert ones stay a div.
  if (onClick) {
    return (
      <button
        type="button"
        className={className}
        aria-current={active ? 'page' : undefined}
        title={collapsed ? label : undefined}
        onClick={onClick}
      >
        {inner}
      </button>
    );
  }
  return (
    <div
      className={className}
      aria-current={active ? 'page' : undefined}
      title={collapsed ? label : undefined}
    >
      {inner}
    </div>
  );
}
