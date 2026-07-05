# Web POS Visual Redesign, Stateful Theme Override, and Collapsible Sidebar

The Web POS visual styling is upgraded to match the premium, custom-branded experience of the mobile client, while adding manual controls tailored for web users.

## Context

The initial Web POS skeleton featured simple CSS layouts with hardcoded color variables, default system fonts, and automatic light/dark colors matching the browser's system preference. Cashiers and administrative users requested a highly refined desktop-first user interface that looks modernized and exquisite, supports manual light/dark/system mode overrides in the app interface, uses high-quality typography, allows collapsing the sidebar navigation to reclaim horizontal space for product cards, and replicates the brand's exact signature gradients.

## Decisions

1. **Stateful Theme Provider & Context**: Implement a client-side theme provider context that governs the theme mode (`light | dark | system`) and resolves the theme dynamically. Store the setting in `localStorage` under `theme-mode`.
2. **Flash of Unstyled Content (FOUC) Prevention**: Embed a synchronous blocking script inside the HTML `<head>` tag to retrieve the user's stored theme (or system fallback) and set the `data-theme` attribute and `colorScheme` property before React hydrates the page.
3. **Plus Jakarta Sans Typography**: Load the premium sans-serif geometric font `Plus Jakarta Sans` via Next.js's optimized `next/font/google` loader.
4. **Selective Glassmorphism**: Apply `backdrop-filter: blur(12px)` and translucent backgrounds (`color-mix` with `transparent`) strictly on fixed floating containers—including the top bar, navigation sidebar, overlay dialog backdrops, and menu panels—to convey depth without sacrificing content readability. Keep product cards and data tables opaque with refined borders and shadows.
5. **Collapsible Navigation Rail**: Add an in-memory toggle state for the sidebar navigation. Clicking the hamburger button shrinks the sidebar from `240px` (desktop expanded) into a `76px` narrow rail (icons-only) or hides it on smaller screens, maximizing product grid space.
6. **Mobile Gradient Replication**: Port the mobile app's signature gradients using standard CSS `color-mix()` functions to blend values directly from theme variables:
   - Primary button/badge gradient: `linear-gradient` fading from `primary` with `80% opacity` to solid `primary`.
   - Glassy page background gradient: `linear-gradient` blending `bg`, `bg + 5% primary`, and `bg + 12% primary`.
   - AmberGlowLine style separator: `linear-gradient` transparent ➔ primary ➔ transparent.

## Consequences

- The web UI matches the exact branding and color configurations chosen by the CEO/business owner, keeping visual parity.
- System preference-only theme switching is replaced by a manual dropdown control in the app shell, with preferences saved across visits.
- Horizontal space forcashiers is highly adjustable on smaller laptop screens via the collapsible sidebar toggle.
- The cart panel remains sticky and permanently visible on viewports >= 900px, ensuring checkout is always one click away on desktop screens.
