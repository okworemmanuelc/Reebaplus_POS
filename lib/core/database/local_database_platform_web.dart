import 'dart:io' show Directory;

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:flutter/foundation.dart';

import 'package:reebaplus_pos/core/services/backup_exclusion_service.dart'
    show kLocalDatabaseFileName;

/// The browser: the same Drift schema in WebAssembly SQLite (#812 S1).
///
/// Needs two files served from `web/`:
/// * `sqlite3.wasm`: the `sqlite3.wasm` asset of sqlite3 3.1.7
///   (https://github.com/simolus3/sqlite3.dart/releases/tag/sqlite3-3.1.7),
///   matching sqlite3 3.1.7 in pubspec.lock.
/// * `drift_worker.js`: drift 2.32.0's worker
///   (https://github.com/simolus3/drift/releases/tag/drift-2.32.0), matching
///   drift 2.32.0 in pubspec.lock.
/// Upgrade both together when drift or sqlite3 moves.
///
/// Drift picks the best storage the browser offers (OPFS, else IndexedDB) and
/// keeps using the one an existing database already lives in. The database is
/// usually hosted by drift's worker, so the open steps (PRAGMAs) that phones
/// run in `localDatabaseOpenSteps` cannot be passed in here: `foreign_keys` is
/// switched on by `AppDatabase`'s `beforeOpen`, and WAL does not apply in the
/// browser. It is still one connection, so the logout wipe's foreign-key and
/// trigger toggles hold.
Future<QueryExecutor> openPlatformLocalDatabase() async {
  final result = await WasmDatabase.open(
    databaseName: kLocalDatabaseFileName,
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.js'),
  );
  if (result.missingFeatures.isNotEmpty) {
    debugPrint(
      '[LocalDatabase] browser storage: ${result.chosenImplementation}; '
      'missing: ${result.missingFeatures}',
    );
  }
  return result.resolvedExecutor;
}

/// The browser has no off-switch file: drift's worker is always used.
Future<void> rememberDbWorkerSwitch(Directory directory, bool? workerOn) async {}
