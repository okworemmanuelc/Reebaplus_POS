import 'package:shared_preferences/shared_preferences.dart';

/// What was saved for a user's active store (#653).
class SavedStorePick {
  const SavedStorePick._(this.storeId);

  /// A deliberate pick of one concrete store.
  const SavedStorePick.store(String id) : this._(id);

  /// A deliberate "All Stores" pick (only an all-stores viewer can make one).
  const SavedStorePick.allStores() : this._(null);

  /// The picked store, or null for "All Stores".
  final String? storeId;

  bool get isAllStores => storeId == null;

  @override
  bool operator ==(Object other) =>
      other is SavedStorePick && other.storeId == storeId;

  @override
  int get hashCode => storeId.hashCode;
}

/// Remembers the store a user deliberately picked, so it survives the app
/// closing and the app locking (#653). One SharedPreferences key per business
/// and user: `active_store.<businessId>.<userId>` = the store id, or
/// [allStoresValue] for a deliberate "All Stores" pick.
///
/// A local preference only: never synced, no Drift or cloud change. It lives
/// outside Drift, so it survives a database wipe; `AppDatabase.clearAllData`
/// and `clearBusinessData` therefore call [clearAll] / [clearForBusiness]
/// (the same wipe-trap pattern as `FirstLoadMarkerService`).
class ActiveStoreMemory {
  static const _prefix = 'active_store.';

  /// The stored value for a deliberate "All Stores" pick.
  static const allStoresValue = '__all__';

  static String keyFor(String businessId, String userId) =>
      '$_prefix$businessId.$userId';

  /// Saves a pick. [storeId] null means "All Stores".
  static Future<void> save(
    String businessId,
    String userId,
    String? storeId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      keyFor(businessId, userId),
      storeId ?? allStoresValue,
    );
  }

  /// The saved pick, or null when nothing (or an empty value) was saved.
  static Future<SavedStorePick?> read(String businessId, String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(keyFor(businessId, userId));
    if (raw == null || raw.isEmpty) return null;
    if (raw == allStoresValue) return const SavedStorePick.allStores();
    return SavedStorePick.store(raw);
  }

  static Future<void> clear(String businessId, String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyFor(businessId, userId));
  }

  /// Removes every user's pick for ONE business (`clearBusinessData`).
  static Future<void> clearForBusiness(String businessId) async {
    final prefs = await SharedPreferences.getInstance();
    final start = '$_prefix$businessId.';
    final keys = prefs.getKeys().where((k) => k.startsWith(start)).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }

  /// Removes every saved pick (`clearAllData`: logout, resign, removal).
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}
