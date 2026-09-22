import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:reebaplus_pos/core/services/backup_exclusion_service.dart'
    show kLocalDatabaseFileName;

const _legacyDbFilename = kLocalDatabaseFileName;
const _cutoverMarkerFilename = '.uuid_cutover_complete_v2';

/// One-time wipe of the legacy SQLite database.
///
/// PR 1 of the UUID cutover: the v36-and-earlier schema is incompatible with
/// the v1 UUID-everywhere schema that PR 2 introduces. Rather than write a
/// v36→v37 int→uuid migration for data that doesn't exist (no production
/// users), we delete the database file before Drift opens it. Drift's
/// onCreate then builds the new schema fresh.
///
/// A marker file is written after the wipe so subsequent launches skip the
/// deletion path entirely.
Future<void> wipeLegacyDatabaseIfPresent() async {
  final dir = await getApplicationDocumentsDirectory();
  final dbPath = p.join(dir.path, _legacyDbFilename);
  final markerPath = p.join(dir.path, _cutoverMarkerFilename);

  final marker = File(markerPath);
  if (await marker.exists()) {
    return;
  }

  final dbFile = File(dbPath);
  if (await dbFile.exists()) {
    await dbFile.delete();
    debugPrint('[db_wipe] Deleted legacy database at $dbPath');
  } else {
    debugPrint('[db_wipe] No legacy database found at $dbPath (fresh install)');
  }

  // Sidecar files (WAL mode + rollback journal). If SQLite was mid-transaction
  // when the app last closed, leaving these behind can cause Drift to read
  // stale state from a database file that no longer exists.
  for (final suffix in const ['-journal', '-wal', '-shm']) {
    final sidecar = File('$dbPath$suffix');
    if (await sidecar.exists()) {
      await sidecar.delete();
      debugPrint('[db_wipe] Deleted sidecar ${sidecar.path}');
    }
  }

  await marker.create();
  debugPrint('[db_wipe] Wrote cutover marker at $markerPath');
}
