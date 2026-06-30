import 'package:shared_preferences/shared_preferences.dart';

/// Persists a per-business "first full pull completed" marker so that:
/// - An established device never shows the first-load overlay again.
/// - A wiped/re-onboarded device correctly gets the overlay on its next pull.
///
/// Stored in SharedPreferences (not Drift) so the marker survives
/// `AppDatabase.clearAllData()` wipes. `clearAllMarkers()` is called explicitly
/// from `clearAllData()` — see the documented clearAllData wipe trap pattern.
class FirstLoadMarkerService {
  static const _prefix = 'first_pull_done_v1_';

  /// Returns true if this business has ever completed a clean full pull on this
  /// device. Returning true suppresses the first-load overlay for this session.
  static Future<bool> hasCompletedPull(String businessId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_prefix$businessId') ?? false;
  }

  /// Marks this business as having completed its first clean full pull.
  /// Called from `SupabaseSyncService.pullChanges` on a successful (skipped==0)
  /// completion.
  static Future<void> markPullCompleted(String businessId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefix$businessId', true);
  }

  /// Removes ALL per-business markers. Called from `AppDatabase.clearAllData()`
  /// (logout / business-delete / onboarding reset) so a re-onboarded device
  /// re-shows the first-load overlay on its next pull.
  static Future<void> clearAllMarkers() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}
