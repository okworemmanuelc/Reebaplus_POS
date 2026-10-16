// Sample data for the Customer Detail tests and goldens (#395 PR 2):
// business "Stallion Global", store "Abuja HQ", made-up customers. Every date
// is a fixed value (never relative to now) so goldens do not drift.

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';

import 'screen_harness.dart';

/// The grants a CEO holds on the customer page.
const customerDetailGrants = {
  'customers.update',
  'customers.delete',
  'customers.wallet.update',
  'customers.set_debt_limit',
  'customers.wallet.withdraw',
  'customers.wallet.totals.view',
  'sales.make',
  'reports.see_sales',
};

/// A bar that tracks crates, so the Crates tab shows.
BusinessData customerDetailBusiness() => BusinessData(
  id: 'biz-1',
  name: 'Stallion Global',
  type: 'bar',
  phone: null,
  email: null,
  logoUrl: null,
  timezone: 'Africa/Lagos',
  onboardingComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
  ownerId: null,
  tracksEmptyCrates: true,
  subscriptionStatus: 'active',
  subscriptionPlan: null,
  trialEndsAt: null,
  currentPeriodEnd: null,
);

/// Providers a Customer Detail pump needs on top of the harness.
List<Override> customerDetailOverrides() => [
  currentBusinessProvider.overrideWith((ref) => customerDetailBusiness()),
];

class CustomerDetailFixture {
  CustomerDetailFixture(this.customerId, this.customer, this.manufacturerId);

  final String customerId;
  final CustomerData customer;
  final String manufacturerId;

  Customer get model => Customer.fromDb(customer);
  Widget get screen => CustomerDetailScreen(customer: model);
}

/// Seeds "Adaeze Okafor" (wholesaler, ₦37,500.00 credit, ₦50,000.00 limit,
/// ₦5,000.00 crate deposit held), three ledger rows, two orders and a crate
/// balance. Needs an environment made with `manufacturerCount: 1`.
Future<CustomerDetailFixture> seedCustomerDetail(
  ScreenTestEnvironment env, {
  String name = 'Adaeze Okafor',
  bool withLedger = true,
}) async {
  final db = env.db;
  final id = UuidV7.generate();
  await db
      .into(db.customers)
      .insert(
        CustomersCompanion.insert(
          id: Value(id),
          businessId: env.businessId,
          name: name,
          phone: const Value('08031112222'),
          address: const Value('12 Allen Avenue, Ikeja'),
          priceTier: const Value('wholesaler'),
          storeId: Value(env.storeId),
          walletLimitKobo: const Value(5000000),
          createdAt: Value(DateTime(2026, 3, 14, 10)),
        ),
      );
  final walletId = UuidV7.generate();
  await db
      .into(db.customerWallets)
      .insert(
        CustomerWalletsCompanion.insert(
          id: Value(walletId),
          businessId: env.businessId,
          customerId: id,
        ),
      );
  Future<void> txn(String type, int kobo, String ref, DateTime at) => db
      .into(db.walletTransactions)
      .insert(
        WalletTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: env.businessId,
          walletId: walletId,
          customerId: id,
          type: type,
          amountKobo: kobo,
          signedAmountKobo: type == 'credit' ? kobo : -kobo,
          referenceType: ref,
          createdAt: Value(at),
        ),
      );
  if (withLedger) {
    await txn('credit', 5000000, 'topup_cash', DateTime(2026, 9, 2, 9, 30));
    await txn('debit', 1250000, 'order_payment', DateTime(2026, 9, 5, 14, 5));
    await txn('credit', 500000, 'crate_deposit', DateTime(2026, 9, 5, 14, 5));
    for (final (n, status, day) in [
      ('ORD-000412-A7K2', 'completed', 5),
      ('ORD-000398-A7K2', 'cancelled', 1),
    ]) {
      await db
          .into(db.orders)
          .insert(
            OrdersCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              orderNumber: n,
              customerId: Value(id),
              totalAmountKobo: 1250000,
              netAmountKobo: 1250000,
              amountPaidKobo: const Value(1250000),
              paymentType: 'cash',
              status: status,
              storeId: Value(env.storeId),
              createdAt: Value(DateTime(2026, 9, day, 14)),
            ),
          );
    }
    await db
        .into(db.crateLedger)
        .insert(
          CrateLedgerCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            customerId: Value(id),
            manufacturerId: Value(env.manufacturers.first.id),
            quantityDelta: 6,
            movementType: 'issued',
          ),
        );
  }
  final data = await (db.select(
    db.customers,
  )..where((t) => t.id.equals(id))).getSingle();
  return CustomerDetailFixture(id, data, env.manufacturers.first.id);
}
