import 'package:supabase_flutter/supabase_flutter.dart';

/// Per-test cleanup helpers, scoped to row ids the test created so we don't
/// touch unrelated data in the shared test business.
///
/// Order matters when there are FK dependencies — payment_transactions
/// reference wallet_transactions, which reference customer_wallets, which
/// reference customers. Delete children before parents.
class TestBusinessFixture {
  final SupabaseClient admin;
  final String businessId;

  TestBusinessFixture(this.admin, this.businessId);

  /// Cleanup after a pos_create_customer test. pos_create_customer writes
  /// only customers + customer_wallets, so cascade is just two tables.
  /// Delete the wallet first (FK references customers).
  ///
  /// If the customer also has leaked append-only ledger rows
  /// (wallet_transactions, payment_transactions — see [deleteTopupRows]),
  /// the wallet/customer can't be deleted because of those FK references.
  /// In that case the cleanup is silently skipped — those rows leak into
  /// the shared test business and accumulate. Reset the test business
  /// periodically.
  Future<void> deleteCustomerCascade(String customerId) async {
    try {
      await admin
          .from('customer_wallets')
          .delete()
          .eq('customer_id', customerId);
      await admin.from('customers').delete().eq('id', customerId);
    } on PostgrestException catch (e) {
      // 23503 = foreign_key_violation. Pinned by leaked ledger rows; leak
      // the customer too rather than crash the test.
      if (e.code != '23503') rethrow;
    }
  }

  /// Cleanup after a pos_wallet_topup test. Both `wallet_transactions` and
  /// `payment_transactions` are append-only ledger tables — the
  /// `forbid_delete` trigger blocks DELETE outright. Tests therefore leak
  /// the topup rows into the shared test business. Acceptable for
  /// dev-machine integration runs; reset the test business periodically if
  /// the ledger grows. Args are retained so call sites don't need changing.
  Future<void> deleteTopupRows({
    required String walletTxnId,
    required String paymentId,
  }) async {
    // intentionally a no-op — see doc above.
  }

  /// Returns the count of rows matching a filter — useful for atomicity
  /// assertions ("zero rows created with this id after a failed RPC").
  Future<int> countById(String table, String id) async {
    final rows = await admin.from(table).select('id').eq('id', id);
    return (rows as List).length;
  }

  /// Cleanup for pos_record_crate_return tests. The cache row is deletable
  /// (it's not append-only), but the underlying `crate_ledger` row is —
  /// `forbid_delete` blocks. Tests therefore leak ledger rows + their
  /// seed customer/manufacturer/crate_group entities into the shared test
  /// business. Acceptable for dev-machine integration runs; reset the
  /// test business periodically if rows accumulate.
  Future<void> deleteCustomerCrateBalance({
    required String customerId,
    required String crateSizeGroupId,
  }) async {
    await admin
        .from('customer_crate_balances')
        .delete()
        .eq('business_id', businessId)
        .eq('customer_id', customerId)
        .eq('crate_size_group_id', crateSizeGroupId);
  }

  Future<void> deleteManufacturerCrateBalance({
    required String manufacturerId,
    required String crateSizeGroupId,
  }) async {
    await admin
        .from('manufacturer_crate_balances')
        .delete()
        .eq('business_id', businessId)
        .eq('manufacturer_id', manufacturerId)
        .eq('crate_size_group_id', crateSizeGroupId);
  }

  /// Reads the balance value for assertions. Returns null if the row
  /// doesn't exist (used to verify zero-rows on failed RPC paths).
  Future<int?> readCustomerCrateBalance({
    required String customerId,
    required String crateSizeGroupId,
  }) async {
    final rows = await admin
        .from('customer_crate_balances')
        .select('balance')
        .eq('business_id', businessId)
        .eq('customer_id', customerId)
        .eq('crate_size_group_id', crateSizeGroupId);
    final list = rows as List;
    if (list.isEmpty) return null;
    return (list.first as Map)['balance'] as int;
  }
}
