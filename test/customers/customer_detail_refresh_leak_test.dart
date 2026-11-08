import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Records every SELECT that reaches the database.
class _SelectSpy extends QueryInterceptor {
  final List<String> selects = [];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects.add(statement);
    return super.runSelect(executor, statement, args);
  }
}

/// Issue #770 — pull-to-refresh on Customer Details re-subscribed its six
/// streams without cancelling the old ones. The orphaned history listener
/// kept running after the screen closed (and read `ref` there).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _SelectSpy spy;
  late AppDatabase db;
  late String businessId, storeId, cId, walletId;
  late CustomerData customerData;
  late ScreenTestEnvironment env;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await initTestSupabase();
    spy = _SelectSpy();
    db = AppDatabase.forTesting(
      DatabaseConnection(
        NativeDatabase.memory().interceptWith(spy),
        closeStreamsSynchronously: true,
      ),
    );
    businessId = UuidV7.generate();
    db.businessIdResolver = () => businessId;
    await db.customSelect('SELECT 1').get();
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Test'),
        );
    storeId = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    final store = await db.storesDao.getStore(storeId);
    cId = UuidV7.generate();
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: Value(cId),
            businessId: businessId,
            name: 'John Doe',
            phone: const Value('08012345678'),
            priceTier: const Value('retailer'),
          ),
        );
    customerData = await (db.select(
      db.customers,
    )..where((t) => t.id.equals(cId))).getSingle();
    walletId = UuidV7.generate();
    await db
        .into(db.customerWallets)
        .insert(
          CustomerWalletsCompanion.insert(
            id: Value(walletId),
            businessId: businessId,
            customerId: cId,
          ),
        );
    env = ScreenTestEnvironment(
      db: db,
      businessId: businessId,
      storeId: storeId,
      store: store!,
      categoryId: UuidV7.generate(),
      products: const [],
      manufacturers: const [],
    );
  });

  testWidgets('refreshing twice then closing leaves no live listener', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      screen: CustomerDetailScreen(customer: Customer.fromDb(customerData)),
      grantedKeys: const {'customers.update'},
      roleRank: GateTier.ceo,
      settle: false,
    );
    Future<void> realWait(int ms) =>
        tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await realWait(50);
    await tester.pump();

    final refresh = tester
        .widget<AppRefreshWrapper>(find.byType(AppRefreshWrapper))
        .onRefresh!;
    await refresh();
    await realWait(50);
    await tester.pump();
    await refresh();
    await realWait(50);
    await tester.pump();

    await disposeScreen(tester);
    await realWait(100);

    spy.selects.clear();
    await tester.runAsync(() async {
      await db
          .into(db.walletTransactions)
          .insert(
            WalletTransactionsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              walletId: walletId,
              customerId: cId,
              type: 'credit',
              amountKobo: 1000,
              signedAmountKobo: 1000,
              referenceType: 'topup_cash',
            ),
          );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    expect(tester.takeException(), isNull);
    expect(
      spy.selects.where((s) => s.contains('wallet_transactions')),
      isEmpty,
      reason: 'a stream from an earlier refresh is still listening',
    );
    // Not closed: with a leaked stream, close() waits on the dead fake clock.
  });
}
