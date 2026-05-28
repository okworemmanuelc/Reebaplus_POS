import 'package:drift/drift.dart' show Variable;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';

/// One row of the row-count audit. `local` is what Drift sees, `remoteAuthed`
/// is what the current Supabase session sees (RLS applies), `remoteService`
/// is what the service-role key sees (RLS bypassed). `Y < Z` means RLS is
/// hiding rows from the user; `Z < X` means rows never made it to the cloud.
class TableDiagnosticRow {
  final String table;
  final int? local;
  final int? remoteAuthed;
  final int? remoteService;
  final String? error;

  const TableDiagnosticRow({
    required this.table,
    this.local,
    this.remoteAuthed,
    this.remoteService,
    this.error,
  });
}

/// Compares local Drift counts with Supabase counts for the current business
/// across every tenant table. Optionally takes a service-role key for the
/// RLS-bypass column; that path is dev-only and the key is never persisted.
class SyncDiagnostic {
  final AppDatabase _db;
  final SupabaseClient _supabase;

  SyncDiagnostic(this._db, {SupabaseClient? client})
      : _supabase = client ?? Supabase.instance.client;

  /// Canonical tenant-table list. Mirrors the syncOrder used by
  /// SupabaseSyncService.pullInitialData. `businesses` is excluded because
  /// it is filtered by `id`, not `business_id`, and there is exactly one row
  /// per business — the count is uninformative here.
  static const List<String> tables = [
    'stores',
    'manufacturers',
    'crate_groups',
    'categories',
    'suppliers',
    'products',
    'inventory',
    'customers',
    'customer_wallets',
    'orders',
    'order_items',
    'wallet_transactions',
    'expenses',
    'expense_categories',
    'customer_crate_balances',
    'delivery_receipts',
    'drivers',
    'stock_transfers',
    'stock_adjustments',
    'activity_logs',
    'notifications',
    'stock_transactions',
    'saved_carts',
    'pending_crate_returns',
    'invites',
  ];

  Future<List<TableDiagnosticRow>> run(
    String businessId, {
    String? serviceRoleKey,
    String? projectUrl,
  }) async {
    SupabaseClient? serviceClient;
    if (serviceRoleKey != null &&
        serviceRoleKey.trim().isNotEmpty &&
        projectUrl != null &&
        projectUrl.trim().isNotEmpty) {
      // One-shot client for the RLS-bypass column. Held only for the duration
      // of run(); never persisted. Requires the user to paste both the project
      // URL and the service-role key in the diagnostic UI.
      serviceClient = SupabaseClient(projectUrl.trim(), serviceRoleKey.trim());
    }

    final results = <TableDiagnosticRow>[];
    for (final table in tables) {
      results.add(await _runOne(table, businessId, serviceClient));
    }
    return results;
  }

  Future<TableDiagnosticRow> _runOne(
    String table,
    String businessId,
    SupabaseClient? serviceClient,
  ) async {
    int? local;
    int? remoteAuthed;
    int? remoteService;
    String? error;

    try {
      local = await _localCount(table, businessId);
    } catch (e) {
      error = 'local: $e';
    }

    try {
      remoteAuthed = await _remoteCount(_supabase, table, businessId);
    } catch (e) {
      error = error == null ? 'authed: $e' : '$error; authed: $e';
    }

    if (serviceClient != null) {
      try {
        remoteService = await _remoteCount(serviceClient, table, businessId);
      } catch (e) {
        error = error == null ? 'service: $e' : '$error; service: $e';
      }
    }

    return TableDiagnosticRow(
      table: table,
      local: local,
      remoteAuthed: remoteAuthed,
      remoteService: remoteService,
      error: error,
    );
  }

  Future<int> _localCount(String table, String businessId) async {
    final row = await _db.customSelect(
      'SELECT COUNT(*) AS c FROM $table WHERE business_id = ?',
      variables: [Variable.withString(businessId)],
    ).getSingle();
    return row.read<int>('c');
  }

  Future<int> _remoteCount(
    SupabaseClient client,
    String table,
    String businessId,
  ) async {
    // .select('id') is light enough — we count length client-side. Using
    // a HEAD-only count via .count(CountOption.exact) would be cheaper but
    // the v2 API surface for it varies; this works on every supported version.
    final rows = await client.from(table).select('id').eq('business_id', businessId);
    return (rows as List).length;
  }
}
