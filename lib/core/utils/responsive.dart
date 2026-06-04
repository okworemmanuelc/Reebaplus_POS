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

  /// The true bottom inset (system nav + keyboard), read from the raw OS view so
  /// an ancestor Scaffold cannot zero it out.
  ///
  /// A Scaffold strips `padding.bottom` from its WHOLE body whenever it has a
  /// `bottomNavigationBar` — even a zero-height one (Flutter scaffold.dart:
  /// `removeBottomPadding: widget.bottomNavigationBar != null`). `MainLayout`'s
  /// app nav bar is never null (it renders `SizedBox.shrink()` when hidden), so
  /// every screen and modal under MainLayout sees `MediaQuery.padding.bottom == 0`
  /// and [bottomInset] reads 0 even though the system nav physically overlaps —
  /// which is why bottom-anchored content paints under the nav bar. Recomputing
  /// from the raw FlutterView bypasses that consumption.
  ///
  /// Use this for bottom-anchored content that reaches the PHYSICAL screen
  /// bottom: modals, bottom-sheet footers, and pushed-screen footers. Do NOT use
  /// it for tab-root content that sits ABOVE the visible bottom nav bar — the bar
  /// already insets those; this would add a spurious gap.
  double get deviceBottomInset {
    final view = View.maybeOf(this);
    if (view == null) return bottomInset;
    final raw = MediaQueryData.fromView(view);
    return raw.padding.bottom + raw.viewInsets.bottom;
  }

  /// The system-navigation inset ONLY (no keyboard), read from the raw OS view
  /// so an ancestor Scaffold can't zero it out. Same source as
  /// [deviceBottomInset] but EXCLUDES the keyboard — use it for bottom-anchored
  /// chrome that the Scaffold already lifts above the keyboard but NOT above the
  /// system nav bar on edge-to-edge (a floating action button is the case this
  /// exists for). Using [deviceBottomInset] there would double-count the
  /// keyboard and jump the button too high when typing.
  double get deviceBottomPadding {
    final view = View.maybeOf(this);
    if (view == null) return MediaQuery.maybeOf(this)?.padding.bottom ?? 0;
    return MediaQueryData.fromView(view).padding.bottom;
  }
}
