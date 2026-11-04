import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'package:reebaplus_pos/core/services/backup_exclusion_service.dart'
    show kLocalDatabaseFileName;

/// Where the local database's one SQLite connection lives (#687).
enum LocalDatabaseHome {
  /// Drift's background worker. The default.
  backgroundWorker,

  /// The screen's thread: the old setup, chosen by the cloud off switch.
  screenThread,
}

/// The `app_config` key behind the off switch (migration 0253).
const String kDbBackgroundWorkerConfigKey = 'db_background_worker';

/// Holds the phone's last answer. A file beside the database, not a database
/// row: it has to be read before the database opens. Not cleared by a logout
/// wipe: it describes the phone, not the shop.
const String kDbWorkerSwitchFileName = '.db_background_worker';

/// Open steps for the one connection. These run on the worker in background
/// mode, so they use nothing but [db]: no globals and no Flutter bindings.
// ignore: prefer_function_declarations_over_variables, drift gives the parameter its type from package:sqlite3, which is not a direct dependency
final DatabaseSetup localDatabaseOpenSteps = (db) {
  db.execute('PRAGMA journal_mode = WAL');
  db.execute('PRAGMA synchronous = NORMAL');
  db.execute('PRAGMA cache_size = -8000');
  db.execute('PRAGMA temp_store = MEMORY');
  db.execute('PRAGMA foreign_keys = ON');
};

/// Runs first on the worker. Must never throw: drift spawns the worker without
/// an error listener, so a throw here would leave every query waiting forever.
///
/// `package:sqlite3` finds the library by name on whichever thread asks
/// (`source: system` in pubspec.yaml), so this only loads it early on Android,
/// where the APK bundles it. iOS and macOS use the system library. If the load
/// fails here, the open reports the same failure to the caller as an error.
void localDatabaseWorkerSetup() {
  if (!Platform.isAndroid) return;
  try {
    DynamicLibrary.open('libsqlite3.so');
  } catch (_) {}
}

/// Opens [file] in [home]. One connection and no read pool on both paths: the
/// logout wipe, the delete guards and several upgrade steps switch foreign keys
/// and triggers off and on, and those only hold on a single connection.
QueryExecutor openLocalDatabaseFile(File file, LocalDatabaseHome home) {
  return switch (home) {
    LocalDatabaseHome.backgroundWorker => NativeDatabase.createInBackground(
      file,
      logStatements: false,
      setup: localDatabaseOpenSteps,
      isolateSetup: localDatabaseWorkerSetup,
    ),
    LocalDatabaseHome.screenThread => NativeDatabase(
      file,
      logStatements: false,
      setup: localDatabaseOpenSteps,
    ),
  };
}

/// Opens the local database in [directory], in the home the phone last
/// remembered. Reads one local file and never touches the network, so it can
/// never hold up opening the app (offline-first entry gate). Called once per
/// app open, so the connection never changes while the app is open.
Future<QueryExecutor> openRememberedLocalDatabase(Directory directory) async {
  final home = await DbWorkerSwitch(directory).rememberedHome();
  return openLocalDatabaseFile(
    File(p.join(directory.path, kLocalDatabaseFileName)),
    home,
  );
}

/// The phone's memory of the cloud off switch.
class DbWorkerSwitch {
  DbWorkerSwitch(Directory directory)
    : _file = File(p.join(directory.path, kDbWorkerSwitchFileName));

  final File _file;

  /// The home for the next open. Only a remembered "off" leaves the worker:
  /// no file, junk or a read failure all mean the background worker.
  Future<LocalDatabaseHome> rememberedHome() async {
    try {
      if (await _file.exists() && (await _file.readAsString()).trim() == 'off') {
        return LocalDatabaseHome.screenThread;
      }
    } catch (_) {}
    return LocalDatabaseHome.backgroundWorker;
  }

  /// Saves a cloud answer for the next open. A null (no answer) keeps the last
  /// one. Never changes the connection that is already open.
  Future<void> remember(bool? workerOn) async {
    if (workerOn == null) return;
    await _file.writeAsString(workerOn ? 'on' : 'off', flush: true);
  }
}
