import 'package:flutter/material.dart';

/// Baseline shortest side for form-factor calculations (iPhone SE / standard Android).
const double _kBaseShortestSide = 375.0;

/// Height at or above which vertical space is comfortable and the form-factor
/// scale governs alone. Below it, scale is cut proportionally so a short
/// viewport fits the same components at lower density.
const double _kComfortableHeight = 700.0;

/// Threshold below which a viewport is considered height-constrained (short).
const double _kShortViewportHeight = 500.0;

/// Upper clamp for spacing (padding, gaps, heights).
///
/// 1.15 since #372 (was 1.50). The largest phones are about 430dp shortest
/// side (430 / 375 = 1.147), so no phone reaches it and phone scale is
/// unchanged; tablets and wide screens land near the 1x sizes the redesign
/// mockups are drawn at instead of 1.5x. One global ceiling, no step at 600dp,
/// so a 580dp foldable is never bigger than a 600dp tablet. See ADR 0025
/// ("Amendment, #372").
const double _kSpacingCeiling = 1.15;

/// Upper clamp for typography (prevents text ballooning on large tablets).
///
/// 1.15 since #372 (was 1.35), the same value as [_kSpacingCeiling] so boxes
/// and text stop growing together on big screens. See ADR 0025.
const double _kFontCeiling = 1.15;

/// Lower clamp for typography (keeps text legible even at highest density).
const double _kFontFloor = 0.90;

/// Lower clamp for spacing in comfortable viewports.
const double _kSpacingFloorComfortable = 0.85;

/// Lower clamp for spacing in short viewports (allows structural compression).
///
/// 0.84 since #352 (was 0.70). A sideways phone is 600dp+ wide, so it gets the
/// side rail instead of the bottom bar and keeps the bar's height for content;
/// the deeper squeeze is no longer needed, and at 0.70 boxes shrank 22% further
/// than text (font floor 0.90), which made landscape look flattened. The brief
/// asked for about 0.85; 0.85 itself pushes POS's chrome 0.9dp past the
/// viewport on a 568x320 sideways phone (still under 600dp, so it keeps the
/// bottom bar) and no product row shows at rest. 0.84 is the highest value the
/// viewport suites pass at. See ADR 0025 ("Amendment, #352").
const double _kSpacingFloorShort = 0.84;

/// Screen width at or above which the app frame swaps the bottom bar for the
/// side rail (PRD #346, #352). Width, not shortest side: a phone turned
/// sideways gets the rail.
const double kRailLayoutMinWidth = 600.0;

/// Screen width at or above which the cart panel is fixed on the right of POS
/// instead of sliding in over a dimmed screen (PRD #346, #352).
const double kWideLayoutMinWidth = 1024.0;

/// Minimum fraction of a short viewport a bottom sheet may be capped to.
/// See [ResponsiveHelper.sheetMaxHeight].
const double _kShortSheetFloor = 0.90;

/// Fallback screen size used when MediaQuery is absent from context.
const Size _kFallbackSize = Size(375.0, 812.0);

/// Why two curves exist:
/// Spacing (padding, gaps, icon boxes, band heights) can compress aggressively
/// in tight or short viewports without loss of utility. Typography cannot —
/// text below 0.90 scale becomes unreadable on mobile screens.
///
/// Why the spacing floor is conditional:
/// Spacing and font previously shared a single scale curve, so their ratio was
/// always exactly 1.0 and text fit its container by construction. Splitting into
/// two curves breaks that invariant. Allowing a 0.70 spacing floor on a
/// comfortable-height device (e.g. iPhone SE1 portrait) produces 18% smaller
/// boxes with 5.5% larger text — a 28% ratio swing across 3,300 call sites
/// nobody will manually review. Holding the spacing floor at 0.85 when the
/// viewport is not short keeps the ratio swing under 6%. Short viewports
/// (height < 500dp, e.g. landscape phones) dropped to 0.70 until #352; the
/// side rail now frees the bottom bar's height there, so the short floor is
/// 0.84, next to 0.85 for comfortable viewports.
double _rawScale(Size size) {
  final formFactor = size.shortestSide / _kBaseShortestSide;
  final heightFactor = (size.height / _kComfortableHeight).clamp(0.0, 1.0);
  return formFactor * heightFactor;
}

double _calcSpacingScale(Size size) {
  final raw = _rawScale(size);
  final isShort = size.height < _kShortViewportHeight;
  final spacingFloor = isShort
      ? _kSpacingFloorShort
      : _kSpacingFloorComfortable;
  return raw.clamp(spacingFloor, _kSpacingCeiling);
}

double _calcFontScale(Size size) {
  final raw = _rawScale(size);
  return raw.clamp(_kFontFloor, _kFontCeiling);
}

/// Scales [baseSize] relative to the device's form factor and vertical room.
/// Uses the typography curve (floored at 0.90, ceiling at 1.15).
double rFontSize(BuildContext context, double baseSize) =>
    context.getRFontSize(baseSize);

/// Returns a fraction of the screen width.
double rWidth(BuildContext context, double fraction) {
  return (MediaQuery.maybeOf(context)?.size.width ?? _kFallbackSize.width) *
      fraction;
}

/// Returns a fraction of the screen height.
double rHeight(BuildContext context, double fraction) {
  return (MediaQuery.maybeOf(context)?.size.height ?? _kFallbackSize.height) *
      fraction;
}

/// Scales a fixed pixel value by the responsive spacing curve.
/// Uses the structural spacing curve (floored at 0.84 short / 0.85 otherwise).
double rSize(BuildContext context, double basePixels) =>
    context.getRSize(basePixels);

/// Extension on BuildContext to easily access responsive dimensions
extension ResponsiveHelper on BuildContext {
  Size get _screenSize => MediaQuery.maybeOf(this)?.size ?? _kFallbackSize;

  /// Returns the width of the screen.
  double get screenWidth => _screenSize.width;

  /// Returns the height of the screen.
  double get screenHeight => _screenSize.height;

  /// Returns the shortest side of the screen (orientation-independent form factor).
  double get screenShortestSide => _screenSize.shortestSide;

  /// Vertical space is scarce (height < 500dp) — collapse or re-flow chrome, never hide it.
  bool get isShortViewport => screenHeight < _kShortViewportHeight;

  /// Form factor, not window width. A phone in landscape is still a phone.
  bool get isPhone => screenShortestSide < 600;

  /// Desktop-width layout for individual screens. Width-driven — but never in a
  /// short window. Until #352 it also drove the permanent 280dp drawer; the
  /// app frame now uses [isRailLayout] / [isWideLayout] instead.
  bool get isDesktop => screenWidth >= 1024 && !isShortViewport;

  /// Tablet form factor, excluding viewports that receive the desktop rail layout.
  bool get isTablet => screenShortestSide >= 600 && !isDesktop;

  /// The app frame shows the side rail (and no bottom bar): screen width at
  /// least [kRailLayoutMinWidth]. The ONE place the frame's navigation width
  /// check lives (#352) — every frame decision reads this or [isWideLayout],
  /// never a raw width. Independent of [isPhone] / [isTablet] / [isDesktop],
  /// which other screens use for their own layouts.
  bool get isRailLayout => screenWidth >= kRailLayoutMinWidth;

  /// The cart panel sits fixed on the right of POS: screen width at least
  /// [kWideLayoutMinWidth]. Always implies [isRailLayout].
  bool get isWideLayout => screenWidth >= kWideLayoutMinWidth;

  /// Width of the app frame's side rail (#352): the spacing curve applied to
  /// 80dp, held between 72dp (room for a 48dp tap target and a nav label on a
  /// sideways phone) and 96dp (kept as a guard; since #372 the 1.15 ceiling
  /// gives 92dp at most, so the 96dp cap no longer binds). Only meaningful when
  /// [isRailLayout].
  double get navRailWidth => getRSize(80).clamp(72.0, 96.0);

  /// Scales a base font size relative to form factor and height (capped 0.90 - 1.15).
  double getRFontSize(double baseSize) =>
      baseSize * _calcFontScale(_screenSize);

  /// Scales a fixed pixel value by the spacing curve (capped 0.84/0.85 - 1.15).
  double getRSize(double basePixels) =>
      basePixels * _calcSpacingScale(_screenSize);

  /// Returns a fraction of the screen width.
  double getRWidth(double fraction) => screenWidth * fraction;

  /// Returns a fraction of the screen height.
  double getRHeight(double fraction) => screenHeight * fraction;

  /// Max height for a bottom sheet, as a fraction of the screen — but never
  /// less than [_kShortSheetFloor] of a short viewport.
  ///
  /// Why a floor and not a plain fraction: a sheet's chrome does NOT compress
  /// with the viewport. A `SegmentedButton` and an `IconButton` are both pinned
  /// at the 48dp tap-target minimum, and `AppInput`/`AppDropdown` bottom out at
  /// 40dp, so a sheet's own minimum height is roughly constant across
  /// orientations while `screenHeight * fraction` collapses by 2.2x on
  /// rotation. `getRHeight(0.5)` on a 915x412 landscape phone yields a 206dp
  /// ceiling under content that cannot shrink below ~265dp — the printer
  /// picker's "BOTTOM OVERFLOWED BY 59 PIXELS", reported 2026-09-06.
  ///
  /// A near-full-height sheet in landscape is the correct Material behaviour
  /// anyway: there is no useful backdrop to reveal in 412dp.
  ///
  /// Use this for every `showModalBottomSheet` `maxHeight`, never bare
  /// [getRHeight] — see `docs/design/responsive-layout-plan.md` §10 gap 6 for
  /// the sites still to migrate.
  double sheetMaxHeight(double fraction) =>
      screenHeight *
      (isShortViewport && fraction < _kShortSheetFloor
          ? _kShortSheetFloor
          : fraction);

  /// Returns EdgeInsets with scaled padding.
  EdgeInsets rPadding(double base) => EdgeInsets.all(getRSize(base));

  /// Returns symmetric EdgeInsets with scaled padding.
  EdgeInsets rPaddingSymmetric({double horizontal = 0, double vertical = 0}) =>
      EdgeInsets.symmetric(
        horizontal: getRSize(horizontal),
        vertical: getRSize(vertical),
      );

  /// Returns directional EdgeInsets with scaled padding.
  EdgeInsets rPaddingOnly({
    double left = 0,
    double top = 0,
    double right = 0,
    double bottom = 0,
  }) => EdgeInsets.only(
    left: getRSize(left),
    top: getRSize(top),
    right: getRSize(right),
    bottom: getRSize(bottom),
  );

  /// Returns the combined bottom padding (safe area + keyboard view insets),
  /// from the nearest MediaQuery.
  ///
  /// Inside `MainLayout` this reads what the frame Scaffold gives its body
  /// (#377): 0 under the bottom bar (the bar owns the system-nav inset, the
  /// Scaffold's resize owns the keyboard), and 0 too on a pushed screen or a
  /// drawer-only tab — use [deviceBottomPadding] there. With the side rail
  /// (600dp+) the body keeps the system-nav inset and the screen owns it.
  double get bottomInset =>
      (MediaQuery.maybeOf(this)?.padding.bottom ?? 0) +
      (MediaQuery.maybeOf(this)?.viewInsets.bottom ?? 0);

  /// The true bottom inset INCLUDING the keyboard (system nav + keyboard), read
  /// from the raw OS view so an ancestor Scaffold cannot zero it out.
  ///
  /// ⚠️ Almost always the WRONG choice in this app — use [deviceBottomPadding].
  /// Every in-app screen lives under `MainLayout`, whose Scaffold
  /// (`resizeToAvoidBottomInset` defaults true, and its nav bar is never null —
  /// it renders `SizedBox.shrink()` when hidden) ALREADY resizes the tab body UP
  /// by the keyboard. Adding the keyboard again via this getter double-counts it,
  /// so bottom-anchored content leaps up "like a second keyboard" when a field is
  /// focused — visible in fixed `Column`s / footer slots, merely wasteful
  /// scroll-extent inside scrollables. Confirmed on-device 2026-06-07 (checkout
  /// crate-deposit sheet). Use [deviceBottomPadding] (nav only) instead.
  ///
  /// Only correct for content that is NOT under MainLayout's resize (a route
  /// shown with `useRootNavigator: true`, or pre-login auth screens) and must
  /// therefore lift itself above the keyboard. The app has no such call sites
  /// today, which is why every former call site now uses [deviceBottomPadding].
  double get deviceBottomInset {
    final view = View.maybeOf(this);
    if (view == null) return bottomInset;
    final raw = MediaQueryData.fromView(view);
    return raw.padding.bottom + raw.viewInsets.bottom;
  }

  /// The system-navigation inset ONLY (no keyboard), read from the raw OS view so
  /// an ancestor Scaffold can't zero it out. THE standard inset for ALL
  /// bottom-anchored content in this app: modals, bottom-sheet footers,
  /// pushed-screen footers, and FABs.
  ///
  /// Why nav-only and not [deviceBottomInset]: every in-app screen is under
  /// `MainLayout`, whose Scaffold already resizes the tab body up by the keyboard,
  /// so the keyboard is handled and content must add ONLY the system-nav inset.
  /// Keyboard down → this clears the nav bar; keyboard up → it collapses to 0 (the
  /// resize covers that). Adding the keyboard here too (via [deviceBottomInset])
  /// double-counts it and jumps content too high.
  ///
  /// Returns 0 above a visible bottom bar (#377). The bottom bar pads itself
  /// by the system-nav inset, so anything that ends at the bar's top edge — a
  /// tab root's own content, a sheet opened on the tab's navigator, the
  /// drawer under 600dp — must not add it again. `MainLayout` marks that
  /// subtree with [BottomBarInsetScope]. Everything else still gets the raw
  /// inset: a screen pushed inside a tab (the bar hides), a drawer-only tab
  /// with no bar (Customers, Expenses, …), the side-rail layout (600dp+, no
  /// bar), and sheets / dialogs / screens on the root navigator, which sit
  /// outside `MainLayout`'s subtree.
  double get deviceBottomPadding {
    if (BottomBarInsetScope.barClearsInset(this)) return 0;
    final view = View.maybeOf(this);
    if (view == null) return MediaQuery.maybeOf(this)?.viewPadding.bottom ?? 0;
    return MediaQueryData.fromView(view).viewPadding.bottom;
  }
}

/// Marks the part of the app frame that sits directly above a visible bottom
/// bar (#377), so [ResponsiveHelper.deviceBottomPadding] returns 0 inside it.
///
/// `MainLayout`'s bottom bar pads itself by the system-navigation inset, and
/// the frame Scaffold takes that inset out of its body's MediaQuery. Content
/// that ends at the bar's top edge has nothing left to clear; adding the raw
/// inset there draws a band of background the height of the system nav
/// between the content and the bar.
///
/// `MainLayout` sets [clearsInset] while the bar is on screen: a nav tab's
/// root, under 600dp wide. It is false on a pushed screen (the bar hides), on
/// a drawer-only tab (no bar) and in the side-rail layout (no bar). Routes on
/// the root navigator are outside the frame's subtree and never see it.
class BottomBarInsetScope extends InheritedWidget {
  const BottomBarInsetScope({
    super.key,
    required this.clearsInset,
    required super.child,
  });

  /// Whether the bottom bar below this subtree already clears the system
  /// navigation inset.
  final bool clearsInset;

  /// Whether [context] sits above a visible bottom bar that already clears
  /// the system navigation inset. False outside any scope.
  static bool barClearsInset(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BottomBarInsetScope>()
          ?.clearsInset ??
      false;

  @override
  bool updateShouldNotify(BottomBarInsetScope oldWidget) =>
      oldWidget.clearsInset != clearsInset;
}
