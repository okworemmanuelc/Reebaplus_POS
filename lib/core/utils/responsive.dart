import 'package:flutter/material.dart';

/// Baseline width used for responsive calculations (iPhone SE / standard Android).
const double _kBaseWidth = 375.0;

/// Maximum scale factor to prevent UI overflow on wide screens (web/desktop).
const double _kMaxScale = 1.5;

/// Returns the clamped scale ratio for the given screen width.
double _scaleFactor(double screenWidth) {
  return (screenWidth / _kBaseWidth).clamp(0.8, _kMaxScale);
}

/// Scales [baseSize] relative to the device's screen width.
/// On a 375px-wide device, returns [baseSize] unchanged.
/// On wider/narrower screens, scales linearly (capped at ${_kMaxScale}x).
double rFontSize(BuildContext context, double baseSize) {
  final sw = MediaQuery.maybeOf(context)?.size.width ?? _kBaseWidth;
  return baseSize * _scaleFactor(sw);
}

/// Returns a fraction of the screen width.
double rWidth(BuildContext context, double fraction) {
  return (MediaQuery.maybeOf(context)?.size.width ?? _kBaseWidth) * fraction;
}

/// Returns a fraction of the screen height.
double rHeight(BuildContext context, double fraction) {
  return (MediaQuery.maybeOf(context)?.size.height ?? 812.0) * fraction;
}

/// Scales a fixed pixel value by the screen-width ratio (capped).
double rSize(BuildContext context, double basePixels) {
  final sw = MediaQuery.maybeOf(context)?.size.width ?? _kBaseWidth;
  return basePixels * _scaleFactor(sw);
}

/// Extension on BuildContext to easily access responsive dimensions
extension ResponsiveHelper on BuildContext {
  /// Returns the width of the screen.
  double get screenWidth => MediaQuery.maybeOf(this)?.size.width ?? _kBaseWidth;

  /// Returns the height of the screen.
  double get screenHeight => MediaQuery.maybeOf(this)?.size.height ?? 812.0;

  /// Clamped scale ratio for this context.
  double get _scale => _scaleFactor(screenWidth);

  /// Breakpoints for responsive design
  bool get isPhone => screenWidth < 600;
  bool get isTablet => screenWidth >= 600 && screenWidth < 1024;
  bool get isDesktop => screenWidth >= 1024;

  /// Scales a base font size relative to screen width (capped).
  double getRFontSize(double baseSize) => baseSize * _scale;

  /// Scales a fixed pixel value by the screen-width ratio (capped).
  double getRSize(double basePixels) => basePixels * _scale;

  /// Returns a fraction of the screen width.
  double getRWidth(double fraction) => screenWidth * fraction;

  /// Returns a fraction of the screen height.
  double getRHeight(double fraction) => screenHeight * fraction;

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

  /// Returns the combined bottom padding (safe area + keyboard view insets).
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
  double get deviceBottomPadding {
    final view = View.maybeOf(this);
    if (view == null) return MediaQuery.maybeOf(this)?.padding.bottom ?? 0;
    return MediaQueryData.fromView(view).padding.bottom;
  }
}
