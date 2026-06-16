import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The selectable design systems. Persisted by `.index` (SharedPreferences) and
/// synced by `.name` — append new values at the end to keep indices stable.
enum DesignSystem { blue, amber, purple, green, bw }

/// Manages theme mode (light / dark / system) and design system (blue / amber).
/// Persists both to SharedPreferences.
class ThemeController extends ChangeNotifier {
  static const _keyThemeMode = 'theme_mode';
  static const _keyDesignSystem = 'design_system';

  ThemeMode _themeMode = ThemeMode.system;
  DesignSystem _designSystem = DesignSystem.amber;

  ThemeMode get themeMode => _themeMode;
  DesignSystem get designSystem => _designSystem;

  /// Call once before runApp.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    final modeIndex = prefs.getInt(_keyThemeMode);
    if (modeIndex != null && modeIndex < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[modeIndex];
    }

    final dsIndex = prefs.getInt(_keyDesignSystem);
    if (dsIndex != null && dsIndex < DesignSystem.values.length) {
      _designSystem = DesignSystem.values[dsIndex];
    }

    notifyListeners();
  }

  void setTheme(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    _persist();
  }

  void toggleTheme() {
    setTheme(_themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }

  void setDesignSystem(DesignSystem ds) {
    if (_designSystem == ds) return;
    _designSystem = ds;
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyThemeMode, _themeMode.index);
    await prefs.setInt(_keyDesignSystem, _designSystem.index);
  }
}

/// Global singleton — initialised in main().
final themeController = ThemeController();
