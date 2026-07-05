# PRD — Web POS UI Visual Redesign & Collapsible Sidebar

## Problem Statement

The current Web POS UI has a basic flat aesthetic with system fonts, hardcoded color schemes, and no manual theme toggle. Cashiers and CEOs operating from desktop web browsers want a modern, premium, and visually stunning interface that matches top-tier POS designs, fits the brand aesthetic, supports manual light/dark theme selection, and provides a customizable view that maximizes the product grid space via collapsible navigation.

## Solution

A modernized, highly exquisite visual redesign of the Web POS client featuring:
1. Stateful manual theme selection (Light / Dark / System) with `localStorage` persistence and FOUC (Flash of Un-themed Content) prevention.
2. Plus Jakarta Sans typography integrated via Next.js Google Fonts.
3. Spacious & Cinematic (Modern Premium) visual density, rich gradients, and micro-interactions.
4. Collapsible sidebar navigation rail that toggles open/close to save space.
5. Sticky, always-visible right-hand cart panel on desktop.
6. Highly polished color palettes for `blue`, `amber`, `purple`, `green`, and `bw` that match the mobile app's colors exactly.
7. CSS translations of signature mobile gradients (`primaryGradient`, `glassyBackground`, `AmberGlowLine`) using `color-mix()`.

## User Stories

1. As an Operator, I want to toggle the theme between Light, Dark, and System modes using a dropdown in the header, so that I can adjust the POS readability depending on my environment.
2. As an Operator, I want my theme choice persisted in `localStorage`, so that when I reload the tab or sign back in, the theme preference is preserved.
3. As an Operator, I want the page to load without a visual white flash (FOUC), so that the transition is seamless when using dark mode.
4. As an Operator, I want a collapsible sidebar, so that I can collapse the navigation menu to a narrow icon-only rail (or hide it completely on mobile) to give maximum screen space to the product grid and cart.
5. As an Operator, I want the sidebar collapse state persisted across reloads, so that I do not have to toggle it every time I open the app.
6. As a cashier on a desktop browser, I want the cart panel to always stay visible and sticky on the right, so that I can see the items, totals, and checkout button while clicking products.
7. As an Operator, I want the product cards to render with soft shadows, thin borders, and subtle lifting hover animations, so that the interface feels interactive and responsive.
8. As a CEO, I want the five business palettes (`blue`, `amber`, `purple`, `green`, `bw`) to use the exact mobile color values, so that the branding looks premium and consistent across platforms in both light and dark modes.
9. As an Operator, I want the UI text to render using the Plus Jakarta Sans font, so that the numbers, quantities, and labels look clean and professional.
10. As an Operator, I want interactive form controls (like checked checkboxes and inputs) to use the active brand accent color, so that form interactions match the active business theme.
11. As an Operator, I want the page background to feature a glassy gradient that blends the base background with a touch of the primary accent, matching the mobile app's signature page styling.

## Implementation Decisions

- **Stateful Theme Provider**: Architect a client-side `ThemeProvider` context that exposes `themeMode`, `resolvedTheme`, and `setThemeMode`. Store the preference under `theme-mode` in `localStorage`.
- **FOUC Prevention Script**: Inject a small blocking script inside the HTML `<head>` (in `layout.tsx`) that reads `localStorage.getItem('theme-mode')` and applies `data-theme` and `style.colorScheme` immediately.
- **Collapsible Sidebar**: Add a toggle button (e.g. ☰) next to the logo in the header. Manage the expanded/collapsed state locally and store in `localStorage`.
- **Vanilla CSS Layout & Variables**: Update `globals.css` with clean CSS custom properties that inherit oklch color palettes dynamically. Apply `backdrop-filter: blur(12px)` selectively on the sticky header, collapsed/expanded sidebar, overlays, and dropdowns.
- **Plus Jakarta Sans Typography**: Import `Plus_Jakarta_Sans` in Next.js `layout.tsx` and apply it root-wide.
- **Mobile Gradient Replication**: Map the custom properties like `--primary`, `--bg`, `--surface`, etc. in `palettes.ts` and define gradients:
  - `primaryGradient` using `linear-gradient(135deg, color-mix(in srgb, var(--primary) 80%, transparent) 0%, var(--primary) 100%)`.
  - `glassyBackground` using `linear-gradient(135deg, var(--bg) 0%, color-mix(in srgb, var(--primary) 5%, var(--bg)) 50%, color-mix(in srgb, var(--primary) 12%, var(--bg)) 100%)`.
  - `AmberGlowLine` using `linear-gradient(90deg, transparent 0%, var(--primary) 50%, transparent 100%)`.

## Testing Decisions

- Only test external behavior, not implementation details.
- Verify typescript check compiles without errors: `npm run typecheck`.
- Build the Next.js bundle successfully: `npm run build`.

## Out of Scope

- Offline-first capabilities for the Web POS (remains online-first as per ADR 0007).
- Changing database schemas or Supabase RPC signatures.
