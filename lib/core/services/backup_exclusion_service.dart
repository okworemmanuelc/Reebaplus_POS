import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Keeps the local Drift database out of the phone's OS backups (#285).
///
/// Android does this declaratively in the manifest (`allowBackup="false"` plus
/// `dataExtractionRules`, which also covers device-to-device transfer). iOS has
/// no manifest equivalent: a file under Documents is backed up to iCloud unless
/// it carries `NSURLIsExcludedFromBackupKey`, which only native code can set —
/// hence the one method channel this class wraps.
///
/// Why exclude it at all: the database is a till's local source of truth, and a
/// restore brings it back WITHOUT the secure-storage session that scopes it. A
/// restored copy can therefore land on a phone whose signed-in identity belongs
/// to a different business — the stale-business state #285 exists to clear.
class BackupExclusionService {
  static const _channel = MethodChannel('reebaplus/backup_exclusion');

  /// Marks the database (and its WAL sidecars) as excluded from iCloud backup.
  /// No-op off iOS. Best-effort: never throws, because failing to set a backup
  /// attribute must not stop the till from opening.
  static Future<void> excludeLocalDatabase() async {
    if (!Platform.isIOS) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      await _channel.invokeMethod<bool>('excludeFromICloudBackup', {
        'path': p.join(dir.path, kLocalDatabaseFileName),
      });
    } catch (e) {
      debugPrint('[BackupExclusion] iCloud exclusion failed: $e');
    }
  }
}

/// The on-disk name of the Drift database, shared by everything that has to
/// find the file rather than open it through Drift.
const kLocalDatabaseFileName = 'reebaplus_pos.sqlite';
