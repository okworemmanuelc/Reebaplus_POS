# Redesign mockups (PRD #346)

These are the designer's mockups for the app-wide redesign. Every redesign agent compares its work against them, and so does the supervisor's side-by-side check of the golden snapshot tests.

**Where a mockup and PRD #346 disagree, PRD #346 wins.** The PRD and its comments hold the owner's later decisions. The main ones:

- **Side rail.** The phone-sideways Home mockup sets the rail style for every size: POS raised, and the selected item shown as a filled blue icon with a blue label and no pill.
- **The mockups are a design language.** Only the screens below get matched pixel for pixel. Every other screen is rebuilt from the same parts.
- **Icons.** Material Symbols Outlined w400, used only through `AppIcons` (#350).
- **Sample data.** Business "Stallion Global", store "Abuja HQ", user "Emmanuel Okwor".

All images are at 2× scale. The logical size is half the pixel size.

| File | Device | Logical size | Theme |
|---|---|---|---|
| `phone-home-dark.png` / `-light` | Phone upright: Home | 390×844 | dark / light |
| `phone-pos-dark.png` / `-light` | Phone upright: POS (bottom bar, View Cart bar) | 390×844 | dark / light |
| `phone-drawer-dark.png` | Phone upright: drawer open | 390×844 | dark only (follow the wide light drawer for light) |
| `phone-ceo-settings-light.png` | Phone upright: CEO Settings | 390×844 | light only (follow the dark tokens for dark) |
| `phone-landscape-home-dark.png` | Phone sideways: Home (rail, 3 card columns) | 844×390 | dark |
| `tablet-pos-dark.png` / `-light` | Tablet upright: POS, cart closed | 800×1280 | dark / light |
| `tablet-cart-panel-dark.png` / `-light` | Tablet upright: cart slide-in panel over a dimmed grid | 800×1280 | dark / light |
| `wide-pos-cart-dark.png` / `-light` | Wide: POS with the fixed cart panel | 1280×800 | dark / light |
| `wide-drawer-dark.png` / `-light` | Wide: drawer open over POS | 1280×800 | dark / light |

The golden snapshot sizes are 390×844, 844×390, 800×1280 and 1280×800 (PRD #346, "Mechanics").
