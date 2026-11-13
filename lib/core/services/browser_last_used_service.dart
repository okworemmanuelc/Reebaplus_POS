import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long a browser copy of the shop may sit unused before it is wiped
/// (#812 S5). Browser-only: phones and tablets never use this rule.
const Duration kBrowserUnusedWipeAfter = Duration(days: 30);

/// Minimum gap between two "last used" writes, so resume events do not hammer
/// storage.
const Duration kBrowserLastUsedWriteGap = Duration(hours: 1);

/// Keeps a "last used" date for the browser copy of the shop (#812 S5) in
/// SharedPreferences (localStorage on web). The decision is the pure
/// [shouldWipe]; the wipe itself is done by AuthService through the normal
/// teardown.
class BrowserLastUsedService {
  BrowserLastUsedService._();

  @visibleForTesting
  static const prefsKey = 'browser_last_used_at';

  static DateTime? _lastWrite;

  /// True when the copy was last used more than [after] before [now]. A
  /// missing date (first run of this feature) keeps the data.
  static bool shouldWipe({
    required DateTime now,
    required DateTime? lastUsed,
    Duration after = kBrowserUnusedWipeAfter,
  }) {
    if (lastUsed == null) return false;
    return now.difference(lastUsed) > after;
  }

  /// The stored last-used date, or null when none / unreadable.
  static Future<DateTime?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(prefsKey);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (e) {
      debugPrint('[BrowserLastUsed] read failed: $e');
      return null;
    }
  }

  /// Stamps "now", at most once per [kBrowserLastUsedWriteGap]. [force] skips
  /// the debounce (used at cold start after the wipe check).
  static Future<void> touch({DateTime? now, bool force = false}) async {
    final t = now ?? DateTime.now();
    final last = _lastWrite;
    if (!force &&
        last != null &&
        t.difference(last) < kBrowserLastUsedWriteGap) {
      return;
    }
    _lastWrite = t;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(prefsKey, t.millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('[BrowserLastUsed] write failed: $e');
    }
  }

  @visibleForTesting
  static void resetDebounceForTest() => _lastWrite = null;
}
