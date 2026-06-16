import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/logger.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

/// One row read from `migration_events` (or the flat-file mirror written by
/// MigrationLogger when a critical error rolls back its in-DB write).
class MigrationEventSummary {
  final int version;
  final String step;
  final String severity; // 'warning' | 'error'
  final String? errorMessage;
  final DateTime occurredAt;

  const MigrationEventSummary({
    required this.version,
    required this.step,
    required this.severity,
    required this.occurredAt,
    this.errorMessage,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'step': step,
    'severity': severity,
    'error_message': errorMessage,
    'occurred_at': occurredAt.toIso8601String(),
  };

  /// Dedupe key — matches the natural identity of an event.
  String get _key => '$version|$step|${occurredAt.toIso8601String()}';
}

/// One column the running code expects but SQLite is missing.
class SchemaColumnIssue {
  final String table;
  final String expectedColumn;
  final String expectedType;
  bool healed;
  String? healError;

  SchemaColumnIssue({
    required this.table,
    required this.expectedColumn,
    required this.expectedType,
    this.healed = false,
    this.healError,
  });

  Map<String, dynamic> toJson() => {
    'table': table,
    'expected_column': expectedColumn,
    'expected_type': expectedType,
    'healed': healed,
    if (healError != null) 'heal_error': healError,
  };
}

/// A Drift-defined table that is entirely absent from SQLite.
class SchemaTableIssue {
  final String table;
  bool healed;
  String? healError;

  SchemaTableIssue({required this.table, this.healed = false, this.healError});

  Map<String, dynamic> toJson() => {
    'table': table,
    'healed': healed,
    if (healError != null) 'heal_error': healError,
  };
}

class SchemaAuditResult {
  final int schemaVersion;
  final DateTime ranAt;
  final List<SchemaColumnIssue> missingColumns;
  final List<SchemaTableIssue> missingTables;
  final List<MigrationEventSummary> recentMigrationEvents;
  final bool fatal;
  final String? reportPath;

  /// Telemetry identifiers (best-effort; null when not yet known).
  final String? deviceUserId;
  final String? businessId;

  const SchemaAuditResult({
    required this.schemaVersion,
    required this.ranAt,
    required this.missingColumns,
    required this.missingTables,
    required this.fatal,
    this.recentMigrationEvents = const [],
    this.reportPath,
    this.deviceUserId,
    this.businessId,
  });

  bool get hasAnyIssue => missingColumns.isNotEmpty || missingTables.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'ran_at': ranAt.toIso8601String(),
    'fatal': fatal,
    'platform': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'device_user_id': deviceUserId,
    'business_id': businessId,
    'missing_tables': missingTables.map((t) => t.toJson()).toList(),
    'missing_columns': missingColumns.map((c) => c.toJson()).toList(),
    'recent_migration_events': recentMigrationEvents
        .map((e) => e.toJson())
        .toList(),
  };
}

/// Compares the actual SQLite schema against Drift's declared schema and
/// optionally self-heals (ALTER TABLE / CREATE TABLE). Writes a JSON report
/// to the app's documents directory so support can retrieve it from device.
///
/// See app_database.dart `beforeOpen` for the wiring point and the v33
/// migration block (lines 778-800) for the silent-failure precedent that
/// motivated this audit.
class SchemaAudit {
  final AppDatabase db;

  /// Factory for the Drift `Migrator`. `createMigrator()` is `@protected` on
  /// `GeneratedDatabase`, so callers from inside `AppDatabase` pass
  /// `() => createMigrator()` to grant the audit heal access.
  final Migrator Function() migratorFactory;

  SchemaAudit(this.db, {required this.migratorFactory});

  Future<SchemaAuditResult> run({required bool attemptHeal}) async {
    final missingColumns = <SchemaColumnIssue>[];
    final missingTables = <SchemaTableIssue>[];

    for (final table in db.allTables) {
      final tableInfo = table as TableInfo;
      final actualName = tableInfo.actualTableName;

      final actualColumns = await _readActualColumns(actualName);
      if (actualColumns == null) {
        missingTables.add(SchemaTableIssue(table: actualName));
        continue;
      }

      for (final col in tableInfo.$columns) {
        if (!actualColumns.contains(col.name)) {
          missingColumns.add(
            SchemaColumnIssue(
              table: actualName,
              expectedColumn: col.name,
              expectedType: col.type.toString(),
            ),
          );
        }
      }
    }

    if (attemptHeal &&
        (missingTables.isNotEmpty || missingColumns.isNotEmpty)) {
      await _heal(missingTables, missingColumns);
    }

    final fatal =
        missingColumns.any((c) => !c.healed) ||
        missingTables.any((t) => !t.healed);

    final telemetry = await _collectTelemetry();
    final recentMigrationEvents = await _readMigrationEvents();

    final reportPath = await _writeReport(
      schemaVersion: db.schemaVersion,
      missingColumns: missingColumns,
      missingTables: missingTables,
      recentMigrationEvents: recentMigrationEvents,
      fatal: fatal,
      deviceUserId: telemetry.$1,
      businessId: telemetry.$2,
    );

    if (missingColumns.isNotEmpty || missingTables.isNotEmpty) {
      AppLogger.error(
        '[SchemaAudit] missingTables=${missingTables.length} '
        'missingColumns=${missingColumns.length} fatal=$fatal '
        'report=$reportPath',
      );
    }

    return SchemaAuditResult(
      schemaVersion: db.schemaVersion,
      ranAt: DateTime.now(),
      missingColumns: missingColumns,
      missingTables: missingTables,
      recentMigrationEvents: recentMigrationEvents,
      fatal: fatal,
      reportPath: reportPath,
      deviceUserId: telemetry.$1,
      businessId: telemetry.$2,
    );
  }

  /// Read recent migration events from both the in-DB `migration_events`
  /// table and the flat-file fallback that survives transaction rollbacks.
  /// Deduped by (version, step, occurredAt), most-recent first, capped at 20.
  Future<List<MigrationEventSummary>> _readMigrationEvents() async {
    final merged = <String, MigrationEventSummary>{};

    // 1) In-DB rows. May fail on a fresh install where the table doesn't
    // exist yet — swallow.
    try {
      final rows = await db
          .customSelect(
            'SELECT version, step, severity, error_message, occurred_at '
            'FROM migration_events ORDER BY id DESC LIMIT 20',
          )
          .get();
      for (final r in rows) {
        final ev = MigrationEventSummary(
          version: r.read<int>('version'),
          step: r.read<String>('step'),
          severity: r.read<String>('severity'),
          errorMessage: r.readNullable<String>('error_message'),
          occurredAt: r.read<DateTime>('occurred_at'),
        );
        merged[ev._key] = ev;
      }
    } catch (_) {}

    // 2) Flat-file rows — survive transaction rollbacks for critical errors.
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final file = File(
        p.join(docsDir.path, 'diagnostics', 'migration_events.jsonl'),
      );
      if (await file.exists()) {
        final lines = await file.readAsLines();
        for (final line in lines.reversed.take(50)) {
          if (line.trim().isEmpty) continue;
          try {
            final j = jsonDecode(line) as Map<String, dynamic>;
            final ev = MigrationEventSummary(
              version: j['version'] as int,
              step: j['step'] as String,
              severity: j['severity'] as String,
              errorMessage: j['error_message'] as String?,
              occurredAt: DateTime.parse(j['occurred_at'] as String),
            );
            merged.putIfAbsent(ev._key, () => ev);
          } catch (_) {
            // Malformed line — skip.
          }
        }
      }
    } catch (_) {}

    final list = merged.values.toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return list.take(20).toList();
  }

  /// Returns the set of column names actually present in SQLite for [tableName],
  /// or `null` if the table itself is absent.
  Future<Set<String>?> _readActualColumns(String tableName) async {
    try {
      final rows = await db
          .customSelect("PRAGMA table_info('$tableName')")
          .get();
      if (rows.isEmpty) return null;
      return rows.map((r) => r.read<String>('name')).toSet();
    } catch (e) {
      AppLogger.error('[SchemaAudit] PRAGMA failed for $tableName', e);
      return null;
    }
  }

  Future<void> _heal(
    List<SchemaTableIssue> missingTables,
    List<SchemaColumnIssue> missingColumns,
  ) async {
    final migrator = migratorFactory();

    // Heal missing tables first — column heals targeting those tables become
    // redundant once createTable runs (createTable installs every column).
    final healedTableNames = <String>{};
    for (final issue in missingTables) {
      final tableInfo = _findTableByName(issue.table);
      if (tableInfo == null) {
        issue.healError = 'no Drift definition found';
        continue;
      }
      try {
        await migrator.createTable(tableInfo);
        issue.healed = true;
        healedTableNames.add(issue.table);
      } catch (e) {
        issue.healError = e.toString();
      }
    }

    for (final issue in missingColumns) {
      if (healedTableNames.contains(issue.table)) {
        // createTable above already installed every declared column.
        issue.healed = true;
        continue;
      }
      final tableInfo = _findTableByName(issue.table);
      if (tableInfo == null) {
        issue.healError = 'no Drift definition found';
        continue;
      }
      final col = tableInfo.columnsByName[issue.expectedColumn];
      if (col == null) {
        issue.healError = 'column not found in Drift definition';
        continue;
      }
      try {
        await migrator.addColumn(tableInfo, col);
        // Re-verify: SQLite ALTER TABLE ADD COLUMN is silent on duplicate
        // (it errors), so success here is sufficient. We still re-read to be
        // defensive.
        final after = await _readActualColumns(issue.table);
        if (after != null && after.contains(issue.expectedColumn)) {
          issue.healed = true;
        } else {
          issue.healError = 'addColumn returned but column still absent';
        }
      } catch (e) {
        issue.healError = e.toString();
      }
    }
  }

  TableInfo? _findTableByName(String actualTableName) {
    for (final table in db.allTables) {
      final ti = table as TableInfo;
      if (ti.actualTableName == actualTableName) return ti;
    }
    return null;
  }

  /// Best-effort: reads device user from secure storage and business_id from
  /// the users table. Either may be null on first-run / pre-login devices.
  Future<(String?, String?)> _collectTelemetry() async {
    String? deviceUserId;
    String? businessId;
    try {
      deviceUserId = await SecureStorageService().getDeviceUserId();
    } catch (_) {}
    if (deviceUserId != null) {
      try {
        final row = await db
            .customSelect(
              'SELECT business_id FROM users WHERE id = ? LIMIT 1',
              variables: [Variable.withString(deviceUserId)],
            )
            .getSingleOrNull();
        businessId = row?.data['business_id'] as String?;
      } catch (_) {
        // users table may itself be missing business_id — that's exactly the
        // kind of corruption this audit is designed to catch. Swallow.
      }
    }
    return (deviceUserId, businessId);
  }

  Future<String?> _writeReport({
    required int schemaVersion,
    required List<SchemaColumnIssue> missingColumns,
    required List<SchemaTableIssue> missingTables,
    required List<MigrationEventSummary> recentMigrationEvents,
    required bool fatal,
    required String? deviceUserId,
    required String? businessId,
  }) async {
    if (missingColumns.isEmpty &&
        missingTables.isEmpty &&
        recentMigrationEvents.isEmpty) {
      return null;
    }
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docsDir.path, 'diagnostics'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
      final file = File(p.join(dir.path, 'schema_audit_$ts.json'));
      final payload = <String, dynamic>{
        'schema_version': schemaVersion,
        'ran_at': DateTime.now().toIso8601String(),
        'fatal': fatal,
        'platform': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'device_user_id': deviceUserId,
        'business_id': businessId,
        'missing_tables': missingTables.map((t) => t.toJson()).toList(),
        'missing_columns': missingColumns.map((c) => c.toJson()).toList(),
        'recent_migration_events': recentMigrationEvents
            .map((e) => e.toJson())
            .toList(),
      };
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );

      await _pruneOldReports(dir);

      return file.path;
    } catch (e) {
      AppLogger.error('[SchemaAudit] failed to write diagnostic report', e);
      return null;
    }
  }

  Future<void> _pruneOldReports(Directory dir) async {
    try {
      final entries =
          (await dir.list().toList())
              .whereType<File>()
              .where((f) => p.basename(f.path).startsWith('schema_audit_'))
              .toList()
            ..sort((a, b) => b.path.compareTo(a.path));
      for (final stale in entries.skip(5)) {
        try {
          await stale.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
