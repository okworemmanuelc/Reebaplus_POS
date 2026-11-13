import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import 'package:reebaplus_pos/core/database/local_database_connection.dart';

/// Phones and tablets: the SQLite file in the app's documents folder, in the
/// home the phone last remembered. Unchanged from before #812.
Future<QueryExecutor> openPlatformLocalDatabase() async =>
    openRememberedLocalDatabase(await getApplicationDocumentsDirectory());

/// Saves the cloud off switch beside the database for the next open.
Future<void> rememberDbWorkerSwitch(Directory directory, bool? workerOn) =>
    DbWorkerSwitch(directory).remember(workerOn);
