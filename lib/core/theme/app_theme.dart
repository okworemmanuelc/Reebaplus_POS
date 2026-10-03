import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class SlideLeftPageTransitionsBuilder extends PageTransitionsBuilder {
  const SlideLeftPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final offset = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: Curves.fastOutSlowIn,
    ));
    return SlideTransition(
      position: offset,
      child: child,
    );
  }
}

class AppTheme {
  AppTheme._();

  // ═══════════════════════════════════════════════════════════════════════════
  // BLUE CLASSIC (original)
  // ═══════════════════════════════════════════════════════════════════════════

  // Shared semantic-color palettes per design system.
  static const _blueSemantics = AppSemanticColors(
    success: successGreen,
    warning: Color(0xFFFFB020),
    info: Color(0xFF3B82F6),
  );
  static const _amberSemantics = AppSemanticColors(
    success: successGreen,
    warning: Color(0xFFFFB020),
    info: Color(0xFF3B82F6),
  );
  static const _purpleSemantics = AppSemanticColors(
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    info: purplePrimary,
  );
  static const _greenSemantics = AppSemanticColors(
    success: greenPrimary,
    warning: Color(0xFFFFB020),
    info: Color(0xFF3B82F6),
  );
  // B&W chrome is monochrome, but status signals stay coloured so profit/loss
  // amounts and warnings remain legible.
  static const _bwSemantics = AppSemanticColors(
    success: Color(0xFF22C55E),
    warning: Color(0xFFFFB020),
    info: Color(0xFF3B82F6),
  );

  // Scheme-driven "project" colours (#349). Every scheme derives its set at
  // Blue's alpha values via AppSchemeColors.derive; only the link hover, the
  // background fade and the muted-on-Surface-2 colour are picked per scheme.
  static final _blueSchemeLight = AppSchemeColors.derive(
    brightness: Brightness.light,
    primary: blueMain,
    surface: lSurface,
    textPrimary: lText,
    linkHover: blueDark,
    backgroundFade: lBgFade,
    mutedOnSurface2: lMutedOnSurface2,
  );
  static final _blueSchemeDark = AppSchemeColors.derive(
    brightness: Brightness.dark,
    primary: bluePrimaryDark,
    surface: dSurface,
    textPrimary: dText,
    linkHover: blueLight,
    backgroundFade: dBgFade,
    mutedOnSurface2: dSubtext,
  );
  static final _amberSchemeLight = AppSchemeColors.derive(
    brightness: Brightness.light,
    primary: contrastAmber,
    surface: alSurface,
    textPrimary: alTextPrimary,
    linkHover: amberLinkHoverLight,
    backgroundFade: AppSchemeColors.fadeFrom(
      brightness: Brightness.light,
      background: alBg,
      primary: contrastAmber,
    ),
    mutedOnSurface2: alTextSecondary,
  );
  static final _amberSchemeDark = AppSchemeColors.derive(
    brightness: Brightness.dark,
    primary: amberPrimary,
    surface: adSurface,
    textPrimary: adTextPrimary,
    linkHover: amberLinkHoverDark,
    backgroundFade: AppSchemeColors.fadeFrom(
      brightness: Brightness.dark,
      background: adBg,
      primary: amberPrimary,
    ),
    mutedOnSurface2: adTextSecondary,
  );
  static final _purpleSchemeLight = AppSchemeColors.derive(
    brightness: Brightness.light,
    primary: purplePrimaryDark,
    surface: plSurface,
    textPrimary: plTextPrimary,
    linkHover: purpleDark,
    backgroundFade: AppSchemeColors.fadeFrom(
      brightness: Brightness.light,
      background: plBg,
      primary: purplePrimaryDark,
    ),
    mutedOnSurface2: plMutedOnSurface2,
  );
  static final _purpleSchemeDark = AppSchemeColors.derive(
    brightness: Brightness.dark,
    primary: purplePrimary,
    surface: pdSurface,
    textPrimary: pdTextPrimary,
    linkHover: purpleLinkHoverDark,
    backgroundFade: AppSchemeColors.fadeFrom(
      brightness: Brightness.dark,
      background: pdBg,
      primary: purplePrimary,
    ),
    mutedOnSurface2: pdTextSecondary,
  );
  static final _greenSchemeLight = AppSchemeColors.derive(
    brightness: Brightness.light,
    primary: greenContrast,
    surface: glSurface,
    textPrimary: glTextPrimary,
    linkHover: greenDark,
    backgroundFade: AppSchemeColors.fadeFrom(
      brightness: Brightness.light,
      background: glBg,
      primary: greenContrast,
    ),
    mutedOnSurface2: glMutedOnSurface2,
  );
  static final _greenSchemeDark = AppSchemeColors.derive(
    brightness: Brightness.dark,
    primary: greenPrimary,
    surface: gdSurface,
    textPrimary: gdTextPrimary,
    linkHover: greenLinkHoverDark,
    backgroundFade: AppSchemeColors.fadeFrom(
      brightness: Brightness.dark,
      background: gdBg,
      primary: greenPrimary,
    ),
    mutedOnSurface2: gdTextSecondary,
  );
  // B&W: hover goes one step further from the background (pure black on
  // light, pure white on dark); its muted text is already the darker step.
  static final _bwSchemeLight = AppSchemeColors.derive(
    brightness: Brightness.light,
    primary: bwPrimaryLight,
    surface: bwlSurface,
    textPrimary: bwlTextPrimary,
    linkHover: Colors.black,
    backgroundFade: AppSchemeColors.fadeFrom(
      brightness: Brightness.light,
      background: bwlBg,
      primary: bwPrimaryLight,
    ),
    mutedOnSurface2: bwlTextSecondary,
  );
  static final _bwSchemeDark = AppSchemeColors.derive(
    brightness: Brightness.dark,
    primary: bwPrimaryDark,
    surface: bwdSurface,
    textPrimary: bwdTextPrimary,
    linkHover: Colors.white,
    backgroundFade: AppSchemeColors.fadeFrom(
      brightness: Brightness.dark,
      background: bwdBg,
      primary: bwPrimaryDark,
    ),
    mutedOnSurface2: bwdTextSecondary,
  );

  static ThemeData light() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    extensions: [_blueSemantics, AppFixedColors.light, _blueSchemeLight],
    scaffoldBackgroundColor: lBg,
    primaryColor: blueMain,
    colorScheme: const ColorScheme.light(
      primary: blueMain,
      secondary: blueLight,
      surface: lSurface,
      onSurface: lText,
      error: danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: lSurface,
      foregroundColor: lText,
      elevation: 0,
      centerTitle: false,
      toolbarHeight: kToolbarHeight + 12,
      shadowColor: lBorder,
      surfaceTintColor: Colors.transparent,
      shape: Border(bottom: BorderSide(color: lBorder, width: 1.5)),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: lSurface,
      selectedItemColor: blueMain,
      unselectedItemColor: Colors.grey,
      showSelectedLabels: true,
      showUnselectedLabels: true,
      type: BottomNavigationBarType.fixed,
    ),
    cardColor: lSurface,
    cardTheme: CardThemeData(
      color: lSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerColor: lBorder,
    chipTheme: ChipThemeData(
      backgroundColor: lCard,
      selectedColor: lText,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      side: BorderSide.none,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    iconTheme: const IconThemeData(color: lSubtext),
    textTheme: const TextTheme(
      displayLarge: TextStyle(color: lText, fontWeight: FontWeight.w700),
      bodyMedium: TextStyle(color: lText),
      bodySmall: TextStyle(color: lSubtext),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: lCard,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: blueMain, width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: danger, width: 1.5),
      ),
      hintStyle: const TextStyle(
        color: lSubtext,
        fontSize: 13,
        fontWeight: FontWeight.w400,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: blueMain,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 0,
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: SlideLeftPageTransitionsBuilder(),
        TargetPlatform.iOS: SlideLeftPageTransitionsBuilder(),
        TargetPlatform.windows: SlideLeftPageTransitionsBuilder(),
        TargetPlatform.macOS: SlideLeftPageTransitionsBuilder(),
        TargetPlatform.linux: SlideLeftPageTransitionsBuilder(),
      },
    ),
  );

  static ThemeData dark() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    extensions: [_blueSemantics, AppFixedColors.dark, _blueSchemeDark],
    scaffoldBackgroundColor: dBg,
    primaryColor: bluePrimaryDark,
    colorScheme: const ColorScheme.dark(
      primary: bluePrimaryDark,
      // Text and icons on the blue gradient are white in dark mode too
      // (colour sheet, #349); ColorScheme.dark defaults onPrimary to black.
      onPrimary: Colors.white,
      secondary: blueLight,
      surface: dSurface,
      onSurface: dText,
      error: danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: dSurface,
      foregroundColor: dText,
      elevation: 0,
      centerTitle: false,
      toolbarHeight: kToolbarHeight + 12,
      shadowColor: dBorder,
      surfaceTintColor: Colors.transparent,
      shape: Border(bottom: BorderSide(color: dBorder, width: 1.5)),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: dSurface,
      selectedItemColor: bluePrimaryDark,
      unselectedItemColor: Colors.grey,
      showSelectedLabels: true,
      showUnselectedLabels: true,
      type: BottomNavigationBarType.fixed,
    ),
    cardColor: dCard,
    cardTheme: CardThemeData(
      color: dCard,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerColor: dBorder,
    chipTheme: ChipThemeData(
      backgroundColor: dCard,
      selectedColor: bluePrimaryDark,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      side: BorderSide.none,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    iconTheme: const IconThemeData(color: dSubtext),
    textTheme: const TextTheme(
      displayLarge: TextStyle(color: dText, fontWeight: FontWeight.w700),
      bodyMedium: TextStyle(color: dText),
      bodySmall: TextStyle(color: dSubtext),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dCard,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: bluePrimaryDark, width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: danger, width: 1.5),
      ),
      hintStyle: const TextStyle(
        color: dSubtext,
        fontSize: 13,
        fontWeight: FontWeight.w400,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: bluePrimaryDark,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 0,
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: SlideLeftPageTransitionsBuilder(),
        TargetPlatform.iOS: SlideLeftPageTransitionsBuilder(),
        TargetPlatform.windows: SlideLeftPageTransitionsBuilder(),
        TargetPlatform.macOS: SlideLeftPageTransitionsBuilder(),
        TargetPlatform.linux: SlideLeftPageTransitionsBuilder(),
      },
    ),
  );

  // ═══════════════════════════════════════════════════════════════════════════
  // AMBER RIBAPLUS
  // ═══════════════════════════════════════════════════════════════════════════

  static ThemeData amberLight() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
    final textTheme = base.textTheme.copyWith(
      displayLarge: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: alTextPrimary,
      ),
      displayMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: alTextPrimary,
      ),
      displaySmall: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: alTextPrimary,
      ),
      headlineLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: alTextPrimary,
      ),
      headlineMedium: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: alTextPrimary,
      ),
      headlineSmall: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: alTextPrimary,
      ),
      titleLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: alTextPrimary,
      ),
      titleMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: alTextPrimary,
      ),
      titleSmall: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: alTextSecondary,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: alTextPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: alTextPrimary,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: alTextSecondary,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: alTextPrimary,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: alTextPrimary,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: alTextSecondary,
      ),
    );

    return base.copyWith(
      extensions: [_amberSemantics, AppFixedColors.light, _amberSchemeLight],
      scaffoldBackgroundColor: alBg,
      primaryColor: amberPrimary,
      colorScheme: const ColorScheme.light(
        primary: contrastAmber, // Use high-contrast amber for light theme
        secondary: amberDark,
        surface: alSurface,
        onSurface: alTextPrimary,
        error: dangerRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: alSurface,
        foregroundColor: alTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: kToolbarHeight + 12,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: alBorder, width: 1)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: alSurface,
        selectedItemColor: amberPrimaryDark,
        unselectedItemColor: alTextSecondary,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      cardColor: alSurface,
      cardTheme: CardThemeData(
        color: alSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerColor: alBorder,
      chipTheme: ChipThemeData(
        backgroundColor: alSurface2,
        selectedColor: amberPrimaryDark,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: alTextPrimary,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.black,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      iconTheme: const IconThemeData(color: alTextSecondary),
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: alSurface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: amberPrimary, width: 2.0),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
        hintStyle: const TextStyle(
          color: alTextSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: amberPrimary,
          foregroundColor: Colors.black,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: amberPrimary),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: amberPrimary,
          side: const BorderSide(color: amberPrimary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: alSurface,
        indicatorColor: amberPrimaryDark.withValues(alpha: 0.15),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(color: alBorder, thickness: 1),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: amberPrimary,
        foregroundColor: Colors.black,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.iOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.windows: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.macOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.linux: SlideLeftPageTransitionsBuilder(),
        },
      ),
    );
  }

  static ThemeData amberDarkTheme() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.dark);
    final textTheme = base.textTheme.copyWith(
      displayLarge: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: adTextPrimary,
      ),
      displayMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: adTextPrimary,
      ),
      displaySmall: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: adTextPrimary,
      ),
      headlineLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: adTextPrimary,
      ),
      headlineMedium: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: adTextPrimary,
      ),
      headlineSmall: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: adTextPrimary,
      ),
      titleLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: adTextPrimary,
      ),
      titleMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: adTextPrimary,
      ),
      titleSmall: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: adTextSecondary,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: adTextPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: adTextPrimary,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: adTextSecondary,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: adTextPrimary,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: adTextPrimary,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: adTextSecondary,
      ),
    );

    return base.copyWith(
      extensions: [_amberSemantics, AppFixedColors.dark, _amberSchemeDark],
      scaffoldBackgroundColor: adBg,
      primaryColor: amberPrimary,
      colorScheme: const ColorScheme.dark(
        primary: amberPrimary,
        secondary: amberDark,
        surface: adSurface,
        onSurface: adTextPrimary,
        error: dangerRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: adSurface,
        foregroundColor: adTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: kToolbarHeight + 12,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: adBorder, width: 1)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: adSurface,
        selectedItemColor: amberPrimary,
        unselectedItemColor: adTextSecondary,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      cardColor: adSurface2,
      cardTheme: CardThemeData(
        color: adSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerColor: adBorder,
      chipTheme: ChipThemeData(
        backgroundColor: adSurface2,
        selectedColor: amberPrimary,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: adTextPrimary,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.black,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      iconTheme: const IconThemeData(color: adTextSecondary),
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: adSurface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: amberPrimary, width: 2.0),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
        hintStyle: const TextStyle(
          color: adTextSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: amberPrimary,
          foregroundColor: Colors.black,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: amberPrimary),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: amberPrimary,
          side: const BorderSide(color: amberPrimary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: adSurface,
        indicatorColor: amberPrimary.withValues(alpha: 0.15),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(color: adBorder, thickness: 1),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: amberPrimary,
        foregroundColor: Colors.black,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.iOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.windows: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.macOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.linux: SlideLeftPageTransitionsBuilder(),
        },
      ),
    );
  }

  static ThemeData purpleLight() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
    final textTheme = base.textTheme.copyWith(
      displayLarge: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: plTextPrimary,
      ),
      displayMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: plTextPrimary,
      ),
      displaySmall: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: plTextPrimary,
      ),
      headlineLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: plTextPrimary,
      ),
      headlineMedium: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: plTextPrimary,
      ),
      headlineSmall: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: plTextPrimary,
      ),
      titleLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: plTextPrimary,
      ),
      titleMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: plTextPrimary,
      ),
      titleSmall: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: plTextSecondary,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: plTextPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: plTextPrimary,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: plTextSecondary,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: plTextPrimary,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: plTextPrimary,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: plTextSecondary,
      ),
    );

    return base.copyWith(
      extensions: [_purpleSemantics, AppFixedColors.light, _purpleSchemeLight],
      scaffoldBackgroundColor: plBg,
      primaryColor: purplePrimary,
      colorScheme: const ColorScheme.light(
        primary: purplePrimaryDark,
        secondary: purpleDark,
        surface: plSurface,
        onSurface: plTextPrimary,
        error: dangerRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: plSurface,
        foregroundColor: plTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: kToolbarHeight + 12,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: plBorder, width: 1)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: plSurface,
        selectedItemColor: purplePrimaryDark,
        unselectedItemColor: plTextSecondary,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      cardColor: plSurface,
      cardTheme: CardThemeData(
        color: plSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerColor: plBorder,
      chipTheme: ChipThemeData(
        backgroundColor: plSurface2,
        selectedColor: purplePrimaryDark,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: plTextPrimary,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.black,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      iconTheme: const IconThemeData(color: plTextSecondary),
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: plSurface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: purplePrimary, width: 2.0),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
        hintStyle: const TextStyle(
          color: plTextSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: purplePrimary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: purplePrimary),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: purplePrimary,
          side: const BorderSide(color: purplePrimary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: plSurface,
        indicatorColor: purplePrimaryDark.withValues(alpha: 0.15),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(color: plBorder, thickness: 1),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: purplePrimary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.iOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.windows: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.macOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.linux: SlideLeftPageTransitionsBuilder(),
        },
      ),
    );
  }

  static ThemeData purpleDarkTheme() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.dark);
    final textTheme = base.textTheme.copyWith(
      displayLarge: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: pdTextPrimary,
      ),
      displayMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: pdTextPrimary,
      ),
      displaySmall: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: pdTextPrimary,
      ),
      headlineLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: pdTextPrimary,
      ),
      headlineMedium: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: pdTextPrimary,
      ),
      headlineSmall: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: pdTextPrimary,
      ),
      titleLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: pdTextPrimary,
      ),
      titleMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: pdTextPrimary,
      ),
      titleSmall: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: pdTextSecondary,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: pdTextPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: pdTextPrimary,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: pdTextSecondary,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: pdTextPrimary,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: pdTextPrimary,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: pdTextSecondary,
      ),
    );

    return base.copyWith(
      extensions: [_purpleSemantics, AppFixedColors.dark, _purpleSchemeDark],
      scaffoldBackgroundColor: pdBg,
      primaryColor: purplePrimary,
      colorScheme: const ColorScheme.dark(
        primary: purplePrimary,
        secondary: purpleDark,
        surface: pdSurface,
        onSurface: pdTextPrimary,
        error: dangerRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: pdSurface,
        foregroundColor: pdTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: kToolbarHeight + 12,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: pdBorder, width: 1)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: pdSurface,
        selectedItemColor: purplePrimary,
        unselectedItemColor: pdTextSecondary,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      cardColor: pdSurface2,
      cardTheme: CardThemeData(
        color: pdSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerColor: pdBorder,
      chipTheme: ChipThemeData(
        backgroundColor: pdSurface2,
        selectedColor: purplePrimary,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: pdTextPrimary,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.black,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      iconTheme: const IconThemeData(color: pdTextSecondary),
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: pdSurface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: purplePrimary, width: 2.0),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
        hintStyle: const TextStyle(
          color: pdTextSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: purplePrimary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: purplePrimary),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: purplePrimary,
          side: const BorderSide(color: purplePrimary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: pdSurface,
        indicatorColor: purplePrimary.withValues(alpha: 0.15),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(color: pdBorder, thickness: 1),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: purplePrimary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.iOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.windows: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.macOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.linux: SlideLeftPageTransitionsBuilder(),
        },
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // GREEN FOREST
  // ═══════════════════════════════════════════════════════════════════════════

  static ThemeData greenLight() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
    final textTheme = base.textTheme.copyWith(
      displayLarge: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: glTextPrimary,
      ),
      displayMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: glTextPrimary,
      ),
      displaySmall: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: glTextPrimary,
      ),
      headlineLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: glTextPrimary,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: glTextPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: glTextPrimary,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: glTextSecondary,
      ),
    );

    return base.copyWith(
      extensions: [_greenSemantics, AppFixedColors.light, _greenSchemeLight],
      scaffoldBackgroundColor: glBg,
      primaryColor: greenPrimary,
      colorScheme: const ColorScheme.light(
        primary: greenContrast,
        secondary: greenDark,
        surface: glSurface,
        onSurface: glTextPrimary,
        error: dangerRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: glSurface,
        foregroundColor: glTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: kToolbarHeight + 12,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: glBorder, width: 1)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: glSurface,
        selectedItemColor: greenPrimaryDark,
        unselectedItemColor: glTextSecondary,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      cardColor: glSurface,
      cardTheme: CardThemeData(
        color: glSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerColor: glBorder,
      chipTheme: ChipThemeData(
        backgroundColor: glSurface2,
        selectedColor: greenPrimaryDark,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: glTextPrimary,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      iconTheme: const IconThemeData(color: glTextSecondary),
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glSurface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: greenContrast, width: 2.0),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
        hintStyle: const TextStyle(
          color: glTextSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: greenContrast,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
    );
  }

  static ThemeData greenDarkTheme() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.dark);
    final textTheme = base.textTheme.copyWith(
      displayLarge: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: gdTextPrimary,
      ),
      displayMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: gdTextPrimary,
      ),
      displaySmall: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: gdTextPrimary,
      ),
      headlineLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: gdTextPrimary,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: gdTextPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: gdTextPrimary,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: gdTextSecondary,
      ),
    );

    return base.copyWith(
      extensions: [_greenSemantics, AppFixedColors.dark, _greenSchemeDark],
      scaffoldBackgroundColor: gdBg,
      primaryColor: greenPrimary,
      colorScheme: const ColorScheme.dark(
        primary: greenPrimary,
        secondary: greenDark,
        surface: gdSurface,
        onSurface: gdTextPrimary,
        error: dangerRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: gdSurface,
        foregroundColor: gdTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: kToolbarHeight + 12,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: gdBorder, width: 1)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: gdSurface,
        selectedItemColor: greenPrimary,
        unselectedItemColor: gdTextSecondary,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      cardColor: gdSurface2,
      cardTheme: CardThemeData(
        color: gdSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerColor: gdBorder,
      chipTheme: ChipThemeData(
        backgroundColor: gdSurface2,
        selectedColor: greenPrimary,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: gdTextPrimary,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      iconTheme: const IconThemeData(color: gdTextSecondary),
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: gdSurface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: greenPrimary, width: 2.0),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
        hintStyle: const TextStyle(
          color: gdTextSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: greenPrimary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BLACK & WHITE (monochrome chrome; coloured status via _bwSemantics)
  // ═══════════════════════════════════════════════════════════════════════════

  static ThemeData bwLight() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
    final textTheme = base.textTheme.copyWith(
      displayLarge: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: bwlTextPrimary,
      ),
      displayMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: bwlTextPrimary,
      ),
      displaySmall: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: bwlTextPrimary,
      ),
      headlineLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: bwlTextPrimary,
      ),
      headlineMedium: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: bwlTextPrimary,
      ),
      headlineSmall: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: bwlTextPrimary,
      ),
      titleLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: bwlTextPrimary,
      ),
      titleMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: bwlTextPrimary,
      ),
      titleSmall: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: bwlTextSecondary,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: bwlTextPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: bwlTextPrimary,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: bwlTextSecondary,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: bwlTextPrimary,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: bwlTextPrimary,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: bwlTextSecondary,
      ),
    );

    return base.copyWith(
      extensions: [_bwSemantics, AppFixedColors.light, _bwSchemeLight],
      scaffoldBackgroundColor: bwlBg,
      primaryColor: bwPrimaryLight,
      colorScheme: const ColorScheme.light(
        primary: bwPrimaryLight,
        onPrimary: Colors.white,
        secondary: bwSecondaryLight,
        surface: bwlSurface,
        onSurface: bwlTextPrimary,
        error: dangerRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bwlSurface,
        foregroundColor: bwlTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: kToolbarHeight + 12,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: bwlBorder, width: 1)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: bwlSurface,
        selectedItemColor: bwPrimaryLight,
        unselectedItemColor: bwlTextSecondary,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      cardColor: bwlSurface,
      cardTheme: CardThemeData(
        color: bwlSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerColor: bwlBorder,
      chipTheme: ChipThemeData(
        backgroundColor: bwlSurface2,
        selectedColor: bwPrimaryLight,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: bwlTextPrimary,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      iconTheme: const IconThemeData(color: bwlTextSecondary),
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bwlSurface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: bwPrimaryLight, width: 2.0),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
        hintStyle: const TextStyle(
          color: bwlTextSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: bwPrimaryLight,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: bwPrimaryLight),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: bwPrimaryLight,
          side: const BorderSide(color: bwPrimaryLight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bwlSurface,
        indicatorColor: bwPrimaryLight.withValues(alpha: 0.12),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(color: bwlBorder, thickness: 1),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: bwPrimaryLight,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.iOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.windows: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.macOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.linux: SlideLeftPageTransitionsBuilder(),
        },
      ),
    );
  }

  static ThemeData bwDarkTheme() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.dark);
    final textTheme = base.textTheme.copyWith(
      displayLarge: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: bwdTextPrimary,
      ),
      displayMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: bwdTextPrimary,
      ),
      displaySmall: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: bwdTextPrimary,
      ),
      headlineLarge: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: bwdTextPrimary,
      ),
      headlineMedium: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: bwdTextPrimary,
      ),
      headlineSmall: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: bwdTextPrimary,
      ),
      titleLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: bwdTextPrimary,
      ),
      titleMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: bwdTextPrimary,
      ),
      titleSmall: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: bwdTextSecondary,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: bwdTextPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: bwdTextPrimary,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: bwdTextSecondary,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: bwdTextPrimary,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: bwdTextPrimary,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: bwdTextSecondary,
      ),
    );

    return base.copyWith(
      extensions: [_bwSemantics, AppFixedColors.dark, _bwSchemeDark],
      scaffoldBackgroundColor: bwdBg,
      primaryColor: bwPrimaryDark,
      colorScheme: const ColorScheme.dark(
        primary: bwPrimaryDark,
        onPrimary: Colors.black,
        secondary: bwSecondaryDark,
        surface: bwdSurface,
        onSurface: bwdTextPrimary,
        error: dangerRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bwdSurface,
        foregroundColor: bwdTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: kToolbarHeight + 12,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: bwdBorder, width: 1)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: bwdSurface,
        selectedItemColor: bwPrimaryDark,
        unselectedItemColor: bwdTextSecondary,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      cardColor: bwdSurface2,
      cardTheme: CardThemeData(
        color: bwdSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerColor: bwdBorder,
      chipTheme: ChipThemeData(
        backgroundColor: bwdSurface2,
        selectedColor: bwPrimaryDark,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: bwdTextPrimary,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.black,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      iconTheme: const IconThemeData(color: bwdTextSecondary),
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bwdSurface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: bwPrimaryDark, width: 2.0),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
        hintStyle: const TextStyle(
          color: bwdTextSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: bwPrimaryDark,
          foregroundColor: Colors.black,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: bwPrimaryDark),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: bwPrimaryDark,
          side: const BorderSide(color: bwPrimaryDark),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bwdSurface,
        indicatorColor: bwPrimaryDark.withValues(alpha: 0.16),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(color: bwdBorder, thickness: 1),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: bwPrimaryDark,
        foregroundColor: Colors.black,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.iOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.windows: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.macOS: SlideLeftPageTransitionsBuilder(),
          TargetPlatform.linux: SlideLeftPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// Text styles the Material `TextTheme` has no slot for (PRD #346 decision 2,
/// #349). Both come from fonts bundled in `assets/google_fonts/`
/// (`DMSans-ExtraBold.ttf`, `RobotoMono-Regular.ttf`); runtime fetching is off
/// (`GoogleFonts.config.allowRuntimeFetching = false` in `main.dart`). Sizes are
/// base px scaled with `getRFontSize`. Colour is left unset so the text
/// inherits it from its surroundings (app bar foreground, `DefaultTextStyle`).
extension AppTextStyles on BuildContext {
  /// Base size of [screenTitleStyle].
  static const double screenTitleBaseSize = 18;

  /// Base size of [monoStyle].
  static const double monoBaseSize = 13;

  /// Screen titles, the business name and the "POS" label under the raised
  /// button: DM Sans ExtraBold (800) at base 18.
  TextStyle get screenTitleStyle => GoogleFonts.dmSans(
    fontSize: getRFontSize(screenTitleBaseSize),
    fontWeight: FontWeight.w800,
  );

  /// Codes and IDs only (e.g. "Terminal 01"): Roboto Mono Regular at base 13.
  TextStyle get monoStyle => GoogleFonts.robotoMono(
    fontSize: getRFontSize(monoBaseSize),
    fontWeight: FontWeight.w400,
  );
}
