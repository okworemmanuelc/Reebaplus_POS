import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';

/// The expense red (#652, the owner's Expenses mockups). Every expense surface
/// is red whatever design system is picked, so these are fixed colours like
/// `AppFixedColors`: one set per brightness, never from the scheme.
///
/// Read with `AppExpenseColors.of(context)`. Wrap an expense surface in
/// [ExpenseTheme] so the stock widgets that read `colorScheme.primary`
/// (cursor, focus border, outline buttons, `AppFAB`, date picker) turn red
/// too.
class AppExpenseColors {
  const AppExpenseColors._({
    required this.ink,
    required this.outline,
    required this.tint,
    required this.selectedFill,
    required this.bannerFill,
    required this.bannerInk,
    required this.glow,
    required this.waitingFill,
    required this.waitingInk,
    required this.approvedFill,
    required this.approvedInk,
    required this.rejectedFill,
    required this.rejectedInk,
    required this.panelFill,
    required this.slate,
  });

  /// Gradient start (top-left): buttons, selected chips, header tile.
  static const Color start = fixedExpenseRed;

  /// Gradient end (bottom-right).
  static const Color end = fixedExpenseRedDeep;

  /// Red text and icons: subtitles, "Spent today", Clear, quick-add chips.
  final Color ink;

  /// Selected tile border and error borders.
  final Color outline;

  /// Pale red behind a row's category icon.
  final Color tint;

  /// Pale red fill of a selected category tile.
  final Color selectedFill;

  /// The "Please fix…" banner fill and its text.
  final Color bannerFill;
  final Color bannerInk;

  /// Soft red shadow under gradient buttons.
  final Color glow;

  final Color waitingFill;
  final Color waitingInk;
  final Color approvedFill;
  final Color approvedInk;
  final Color rejectedFill;
  final Color rejectedInk;

  /// The pale slate panels: summary tiles (mockup #F1F5F9).
  final Color panelFill;

  /// Slate labels and idle category icons (mockup #475569).
  final Color slate;

  static final AppExpenseColors light = AppExpenseColors._(
    ink: fixedExpenseInkLight,
    outline: fixedExpenseRed,
    tint: fixedExpenseRed.withValues(alpha: 0.10),
    selectedFill: fixedExpenseRed.withValues(alpha: 0.06),
    bannerFill: fixedExpenseRed.withValues(alpha: 0.09),
    bannerInk: fixedExpenseBannerInkLight,
    glow: fixedExpenseRed.withValues(alpha: 0.30),
    waitingFill: fixedExpenseWaitingFillLight,
    waitingInk: fixedExpenseWaitingInkLight,
    approvedFill: fixedExpenseApprovedFillLight,
    approvedInk: fixedExpenseApprovedInkLight,
    rejectedFill: fixedExpenseRejectedFillLight,
    rejectedInk: fixedExpenseRejectedInkLight,
    panelFill: fixedExpenseRejectedFillLight,
    slate: fixedExpenseRejectedInkLight,
  );

  static final AppExpenseColors dark = AppExpenseColors._(
    ink: fixedExpenseInkDark,
    outline: fixedExpenseRed,
    tint: fixedExpenseRed.withValues(alpha: 0.18),
    selectedFill: fixedExpenseRed.withValues(alpha: 0.16),
    bannerFill: fixedExpenseRed.withValues(alpha: 0.16),
    bannerInk: fixedExpenseBannerInkDark,
    glow: fixedExpenseRed.withValues(alpha: 0.35),
    waitingFill: fixedExpenseWaitingInkLight.withValues(alpha: 0.35),
    waitingInk: fixedExpenseWaitingInkDark,
    approvedFill: fixedExpenseApprovedInkLight.withValues(alpha: 0.40),
    approvedInk: fixedExpenseApprovedInkDark,
    rejectedFill: Colors.white.withValues(alpha: 0.08),
    rejectedInk: fixedExpenseRejectedInkDark,
    panelFill: Colors.white.withValues(alpha: 0.06),
    slate: fixedExpenseRejectedInkDark,
  );

  static AppExpenseColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// The red button gradient, top-left → bottom-right.
  static const LinearGradient gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [start, end],
  );

  /// A red gradient fill with the soft red glow, for buttons and chips.
  BoxDecoration gradientBox({required double radius, bool glow = true}) =>
      BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: this.glow,
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      );
}

/// Re-themes [child] in the expense red: `primary` = #DC2626 and `secondary`
/// = #991B1B (so `AppFAB`'s primary → secondary gradient matches the mockup),
/// a red glow, and in light mode the mockup's pale red page fade. Everything
/// else keeps the user's design system.
class ExpenseTheme extends StatelessWidget {
  const ExpenseTheme({super.key, required this.child});

  final Widget child;

  /// The expense version of [base].
  static ThemeData of(ThemeData base) {
    final scheme = base.extension<AppSchemeColors>();
    final light = base.brightness == Brightness.light;
    final colors = light ? AppExpenseColors.light : AppExpenseColors.dark;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: AppExpenseColors.start,
        secondary: AppExpenseColors.end,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
      ),
      textSelectionTheme: base.textSelectionTheme.copyWith(
        cursorColor: AppExpenseColors.start,
        selectionHandleColor: AppExpenseColors.start,
        selectionColor: AppExpenseColors.start.withValues(alpha: 0.25),
      ),
      extensions: [
        ...base.extensions.values.where((e) => e is! AppSchemeColors),
        if (scheme != null)
          scheme.copyWith(
            primaryGlow: colors.glow,
            primaryTint: colors.selectedFill,
            backgroundFade: light ? fixedExpensePageFadeLight : null,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) =>
      Theme(data: of(Theme.of(context)), child: child);
}
