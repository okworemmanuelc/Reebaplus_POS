# Web POS Visual Redesign, Stateful Theme Override, and Sidebar Navigation

The Web POS visual styling is upgraded to match the premium, custom-branded experience of the mobile client, while adding manual controls and layout structures tailored for web users.

## Context

The initial Web POS skeleton featured simple CSS layouts with hardcoded color variables, default system fonts, and automatic light/dark colors matching the browser's system preference. Cashiers and administrative users requested a highly refined desktop-first user interface that looks modernized and exquisite, supports manual light/dark/system mode overrides in the app interface, uses high-quality typography, allows collapsing the sidebar navigation to reclaim horizontal space for product cards, and replicates the brand's exact signature gradients.

## Decisions

1. **Stateful Theme Provider & Context**: Implement a client-side theme provider context that governs the theme mode (`light | dark | system`) and resolves the theme dynamically. Store the setting in `localStorage` under `theme-mode`.
2. **Flash of Unstyled Content (FOUC) Prevention**: Embed a synchronous blocking script inside the HTML `<head>` tag to retrieve the user's stored theme (or system fallback) and set the `data-theme` attribute and `colorScheme` property before React hydrates the page.
3. **Plus Jakarta Sans Typography**: Load the premium sans-serif geometric font `Plus Jakarta Sans` via Next.js's optimized `next/font/google` loader.
4. **Full-Height Left Navigation Grid**: Structure the layout using CSS grid-template-areas, positioning the navigation sidebar as a full-height column on the left edge, and the top-bar and content area side-by-side on the right.
5. **Selective Glassmorphism & Mesh Background Glows**: Apply `backdrop-filter: blur(12px)` and translucent backgrounds (`color-mix` with `transparent`) strictly on fixed floating containers—including the top bar, navigation sidebar, overlay dialog backdrops, and menu panels—to convey depth without sacrificing content readability. Add pseudo-elements with radial gradients and large blurs on the shell background to create a colorful background mesh glow.
6. **Product Card White Boxes**: Wrap product images inside a solid white rounded box container with `object-fit: contain` and centering padding, isolating the product shape from the background cards and improving product separation.
7. **Outline SVG Icons**: Replace all system/unicode icons in the sidebar and headers with custom, lightweight inline SVGs.
8. **Promoted Cart Provider & Search Integration**: Move the `<CartProvider>` wrapper to the root layout to allow the header search input to share its query value with the product card grid.
9. **Mobile Gradient Replication**: Port the mobile app's signature gradients using standard CSS `color-mix()` functions to blend values directly from theme variables:
   - Primary button/badge gradient: `linear-gradient` fading from `primary` with `80% opacity` to solid `primary`.
   - Glassy page background gradient: `linear-gradient` blending `bg`, `bg + 5% primary`, and `bg + 12% primary`.
   - AmberGlowLine style separator: `linear-gradient` transparent ➔ primary ➔ transparent.

## Consequences

- The web UI matches the exact branding and color configurations chosen by the CEO/business owner, keeping visual parity.
- System preference-only theme switching is replaced by a manual dropdown control in the app shell, with preferences saved across visits.
- Horizontal space for cashiers is highly adjustable on smaller laptop screens via the collapsible sidebar toggle, which collapses items into a stacked narrow rail (icons with labels below).
- The cart panel remains sticky and permanently visible on viewports >= 900px, ensuring checkout is always one click away on desktop screens.
- Global components (search, navigation rail, custom profiles) are highly modularized, utilizing dynamic `--bg`, `--surface`, `--text`, and `--primary` CSS variables, ensuring 100% reusability across future administrative pages.
