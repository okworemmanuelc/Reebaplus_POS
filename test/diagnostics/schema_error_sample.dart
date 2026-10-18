// Sample audit for the Schema error screen tests and goldens (#443). Fixed
// dates, made-up ids; "Stallion Global" is the business.

import 'package:reebaplus_pos/core/diagnostics/schema_audit.dart';

SchemaAuditResult sampleSchemaAudit({bool withReport = true}) =>
    SchemaAuditResult(
      schemaVersion: 85,
      ranAt: DateTime.utc(2026, 3, 14, 9, 30),
      fatal: true,
      businessId: '0192a9d0-1111-7000-8000-stallion00001',
      deviceUserId: '0192a9d0-2222-7000-8000-adaobi000001',
      reportPath: withReport
          ? '/data/user/0/ng.reebaplus.pos/files/schema_audit_20260314.json'
          : null,
      missingTables: [
        SchemaTableIssue(table: 'crate_ledger', healed: false)
          ..healError = 'table creation failed: disk I/O error',
        SchemaTableIssue(table: 'cost_batches', healed: true),
      ],
      missingColumns: [
        SchemaColumnIssue(
          table: 'orders',
          expectedColumn: 'client_ref',
          expectedType: 'TEXT',
        )..healError = 'duplicate column name: client_ref',
        SchemaColumnIssue(
          table: 'products',
          expectedColumn: 'barcode',
          expectedType: 'TEXT',
          healed: true,
        ),
      ],
      recentMigrationEvents: [
        MigrationEventSummary(
          version: 84,
          step: 'add_crate_ledger_reason',
          severity: 'error',
          errorMessage: 'no such table: crate_ledger',
          occurredAt: DateTime.utc(2026, 3, 14, 9, 29),
        ),
        MigrationEventSummary(
          version: 85,
          step: 'index_orders_client_ref',
          severity: 'warning',
          occurredAt: DateTime.utc(2026, 3, 14, 9, 29, 5),
        ),
      ],
    );
