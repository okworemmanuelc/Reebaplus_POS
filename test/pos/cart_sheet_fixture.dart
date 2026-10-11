// Pumps the Cart tab's screen with sample customers and saved carts so the
// two restyled Cart sheets (#393) — Select Customer (Change) and Saved Carts
// (Recall) — can be opened in tests and goldens. Sample data only.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/screens/cart_screen.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';

import '../helpers/screen_harness.dart';
import 'cart_fixture.dart';

/// Adds two customers (one owing, one in credit via the override) and two
/// saved carts for the harness cashier in the environment's store.
Future<List<String>> seedCartSheetData(ScreenTestEnvironment env) async {
  final db = env.db;
  final ids = <String>[];
  for (final name in ['Chinedu Okafor', 'Amaka Eze']) {
    final id = 'cust-${name.split(' ').first.toLowerCase()}';
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: name,
            storeId: Value(env.storeId),
            phone: const Value('0803 000 0000'),
          ),
        );
    ids.add(id);
  }
  for (final (name, hour) in [('Morning Order', 9), ('Bar restock', 14)]) {
    await db.ordersDao.saveCart(
      SavedCartsCompanion.insert(
        name: name,
        cartData: '[]',
        businessId: env.businessId,
        storeId: Value(env.storeId),
        cashierId: const Value('test-user-id'),
        createdAt: Value(DateTime(2026, 10, 11, hour, 30)),
      ),
    );
  }
  return ids;
}

/// Pumps the Cart with the mockup lines and [ids]' balances (first owes
/// ₦12,500, second holds ₦3,000 credit).
Future<void> pumpCartForSheets(
  WidgetTester tester, {
  required ScreenTestEnvironment env,
  required List<String> ids,
  Size size = const Size(390, 844),
  EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 48),
  EdgeInsets viewInsets = EdgeInsets.zero,
  TextScaler? textScaler,
  Brightness brightness = Brightness.light,
  Set<String> grantedKeys = const {'sales.make', 'customers.add'},
}) async {
  await pumpScreen(
    tester,
    env: env,
    size: size,
    padding: padding,
    viewInsets: viewInsets,
    textScaler: textScaler,
    grantedKeys: grantedKeys,
    theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
    screen: _Prefilled(
      fill: fillMockupCart,
      builder: (c) => CartScreen(
        cart: const [],
        activeCustomer: c.activeCustomer.value,
        onCustomerChanged: (_) {},
      ),
    ),
    overrides: [
      firstRunSurfaceStateProvider.overrideWithValue(
        FirstRunSurfaceState.hasContent,
      ),
      creditBalancesKoboProvider.overrideWith(
        (ref) => Stream.value({ids[0]: -1250000, ids[1]: 300000}),
      ),
    ],
    sharedPreferences: const {'hint_cart_tap_edit': 2},
    settle: false,
  );
  await settleCartSheets(tester);
}

Future<void> settleCartSheets(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}

class _Prefilled extends ConsumerStatefulWidget {
  const _Prefilled({required this.fill, required this.builder});

  final void Function(CartService cart) fill;
  final Widget Function(CartService cart) builder;

  @override
  ConsumerState<_Prefilled> createState() => _PrefilledState();
}

class _PrefilledState extends ConsumerState<_Prefilled> {
  bool _filled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.fill(ref.read(cartProvider));
      setState(() => _filled = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    // In the app the balances are already loaded (Home, Customers); keep the
    // stream alive here so the picker opens with them.
    ref.watch(creditBalancesKoboProvider);
    return _filled
        ? widget.builder(ref.read(cartProvider))
        : const SizedBox.shrink();
  }
}
