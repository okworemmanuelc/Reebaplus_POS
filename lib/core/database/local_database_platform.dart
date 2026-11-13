/// Opens the local database on whichever platform the app runs on (#812 S1).
///
/// Phones and tablets get `local_database_platform_native.dart`, which opens
/// the SQLite file exactly as before (`local_database_connection.dart`). The
/// browser gets `local_database_platform_web.dart`, which opens the same Drift
/// schema in WebAssembly SQLite, stored by the browser. Both expose:
///
/// * `openPlatformLocalDatabase()`: the app's one database connection.
/// * `rememberDbWorkerSwitch(directory, workerOn)`: saves the cloud off switch
///   for the next open (phones only; a no-op in the browser).
library;

export 'local_database_platform_native.dart'
    if (dart.library.js_interop) 'local_database_platform_web.dart';
