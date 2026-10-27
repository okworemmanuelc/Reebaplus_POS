import 'package:drift/drift.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

import '../helpers/screen_harness.dart';

/// Seeds the sample business ("Stallion Global") with fixed subscription dates
/// (never `DateTime.now()`) and returns its row.
Future<BusinessData> seedSubscriptionBusiness(
  ScreenTestEnvironment env, {
  String status = 'trial',
}) async {
  final db = env.db;
  await (db.update(
    db.businesses,
  )..where((b) => b.id.equals(env.businessId))).write(
    BusinessesCompanion(
      name: const Value('Stallion Global'),
      subscriptionStatus: Value(status),
      subscriptionPlan: const Value('basic'),
      trialEndsAt: Value(DateTime(2026, 9, 30)),
      currentPeriodEnd: Value(DateTime(2026, 11, 15)),
    ),
  );
  return (db.select(
    db.businesses,
  )..where((b) => b.id.equals(env.businessId))).getSingle();
}
