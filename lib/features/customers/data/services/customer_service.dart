import 'package:flutter/widgets.dart';
import 'package:drift/drift.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/shared/services/activity_log_service.dart';
import 'package:reebaplus_pos/shared/services/credit_ledger_service.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/data/models/payment.dart';

class CustomerService extends ValueNotifier<List<Customer>> {
  final AppDatabase _db;
  final ActivityLogService _log;

  CustomerService(this._db, this._log) : super([]) {
    _init();
  }

  void _init() {
    _db.customersDao.watchAllCustomers().listen((dataList) {
      value = dataList.map((d) => Customer.fromDb(d)).toList();
    });
  }

  List<Customer> getAll() => List.unmodifiable(value);

  Customer? getById(String id) {
    try {
      return value.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<Customer?> addCustomer(Customer customer, {String? businessId}) async {
    if (businessId == null) {
      throw StateError('addCustomer requires a businessId (post-UUID schema)');
    }
    final newId = await _db.customersDao.addCustomer(
      CustomersCompanion.insert(
        name: customer.name,
        phone: Value(customer.phone),
        address: Value(customer.addressText),
        googleMapsLocation: Value(customer.googleMapsLocation),
        priceTier: Value(customer.priceTier.name),
        storeId: Value(customer.storeId),
        businessId: businessId,
      ),
    );

    await _log.logAction(
      'Customer Created',
      'Added new customer: ${customer.name}',
      customerId: newId,
    );

    final data = await _db.customersDao.findById(newId);
    return data != null ? Customer.fromDb(data) : null;
  }

  /// §18 — edit an existing customer's details (CEO/Manager only,
  /// `customers.update`, gated at the UI + the sheet's save boundary). Routes
  /// through the DAO (which enqueues the full row) and logs.
  Future<void> updateCustomer(Customer updatedCustomer) async {
    await _db.customersDao.updateCustomerDetails(
      customerId: updatedCustomer.id,
      name: updatedCustomer.name,
      phone: updatedCustomer.phone,
      address: updatedCustomer.addressText,
      googleMapsLocation: updatedCustomer.googleMapsLocation,
      priceTier: updatedCustomer.priceTier.name,
      storeId: updatedCustomer.storeId,
    );
    await _log.logAction(
      'Customer Updated',
      'Updated details for customer: ${updatedCustomer.name}',
      customerId: updatedCustomer.id,
    );
  }

  /// §18.4 / §18.5 — soft-delete a customer (CEO/Manager only, gated at the
  /// UI). Routes through the DAO (which enqueues the full row) and logs.
  Future<void> softDeleteCustomer(String customerId) async {
    final customer = getById(customerId);
    await _db.customersDao.softDeleteCustomer(customerId);
    await _log.logAction(
      'Customer Deleted',
      'Soft-deleted customer: ${customer?.name ?? customerId}',
      customerId: customerId,
    );
  }

  Future<void> addPayment(String customerId, Payment payment) async {
    final customer = getById(customerId);
    if (customer == null) return;

    final amountKobo = (payment.amount * 100).round();
    // TODO(PR 4d): pass real staff id from auth context once wallet writes restore.
    await _db.customersDao.updateWalletBalance(
      customerId: customerId,
      amountKobo: amountKobo,
      type: 'credit',
      referenceType: 'topup_cash',
      note: payment.note,
      staffId: '',
    );

    await _log.logAction(
      'Payment Added',
      'Added payment of ${formatCurrency(payment.amount)} for ${customer.name}',
      customerId: customer.id,
    );
  }

  Future<void> addCratesToBalance(
    String customerId,
    Map<String, int> cratesAdded,
  ) async {
    final customer = getById(customerId);
    if (customer != null) {
      await _log.logAction(
        'Crates Dispatched',
        'Added $cratesAdded empty crates to balance for ${customer.name}',
        customerId: customer.id,
      );
    }
  }

  Future<void> updateEmptyCratesBalance(
    String customerId,
    Map<String, int> cratesReturned,
  ) async {
    final customer = getById(customerId);
    if (customer != null) {
      await _log.logAction(
        'Crates Returned',
        'Updated empty crates balance for ${customer.name}',
        customerId: customer.id,
      );
    }
  }

  /// §18 Add Credit — top up a registered customer's credit balance. The credit + payment
  /// ledger writes are atomic via CreditLedgerService.topup.
  Future<void> topUpWallet({
    required String customerId,
    required int amountKobo,
    required String method, // 'cash' | 'transfer'
    required String staffId,
    String? note,
  }) async {
    final customer = getById(customerId);
    await CreditLedgerService(_db).topup(
      customerId: customerId,
      amountKobo: amountKobo,
      method: method,
      staffId: staffId,
    );
    final naira = (amountKobo / 100).round();
    await _log.logAction(
      'Payment Added',
      'Added credit of ${formatCurrency(naira)} to ${customer?.name ?? customerId}\'s balance'
          '${note != null && note.isNotEmpty ? '. Note: $note' : ''}',
      customerId: customerId,
    );
  }

  /// §18.3 Refund Cash (CEO/Manager only) — pay the customer back, in cash,
  /// money the business holds for them (held crate deposit and/or positive
  /// spendable credit). Delegates to CreditLedgerService.refundCash, which writes the
  /// wallet + payment ledger, the activity log, and the notification atomically.
  /// Returns the amount actually refunded after capping at what's available.
  Future<int> refundCashFromWallet({
    required String customerId,
    required int amountKobo,
    required String method, // 'cash' | 'transfer' | 'pos' | 'other'
    required String staffId,
    String? note,
  }) {
    return CreditLedgerService(_db).refundCash(
      customerId: customerId,
      amountKobo: amountKobo,
      method: method,
      staffId: staffId,
      note: note,
    );
  }

  Future<void> updateWalletLimit(String customerId, double newLimit) async {
    final customer = getById(customerId);
    if (customer == null) {
      throw StateError('updateWalletLimit: customer $customerId not found');
    }

    final limitKobo = (newLimit * 100).round();
    await _db.customersDao.updateWalletLimit(customerId, limitKobo);

    await _log.logAction(
      'Limit Updated',
      'Updated credit limit to ${formatCurrency(newLimit.abs())} for ${customer.name}',
      customerId: customer.id,
    );
  }

  Future<void> refundToWallet(
    String customerId,
    double amount,
    String note,
  ) async {
    final customer = getById(customerId);
    if (customer == null) return;

    final amountKobo = (amount * 100).round();
    await _db.customersDao.updateWalletBalance(
      customerId: customerId,
      amountKobo: amountKobo,
      type: 'credit',
      referenceType: 'refund',
      note: note,
      staffId: '',
    );

    await _log.logAction(
      'Credit Balance Refunded',
      'Refunded ${formatCurrency(amount)} to ${customer.name}\'s credit balance. Note: $note',
      customerId: customer.id,
    );
  }

  Future<void> updateWalletBalance(
    String customerId,
    double amount,
    String note,
  ) async {
    final customer = getById(customerId);
    if (customer == null) return;

    final amountKobo = (amount * 100).round();
    await _db.customersDao.updateWalletBalance(
      customerId: customerId,
      amountKobo: amountKobo,
      type: 'credit',
      referenceType: 'topup_cash',
      note: note,
      staffId: '',
    );

    await _log.logAction(
      'Credit Balance Updated',
      'Added ${formatCurrency(amount)} to ${customer.name}\'s credit balance. Note: $note',
      customerId: customer.id,
    );
  }
}
