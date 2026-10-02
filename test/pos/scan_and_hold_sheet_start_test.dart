// scan_and_hold_sheet_start_test.dart
//
// #317 — the two ways into the POS "Add to Cart" sheet, side by side on the
// real POS screen, for a product already in the cart ×2:
//   - tap-and-hold on the tile opens on 2 (the cart total, unchanged);
//   - a barcode scan opens on 3 (one more), over the scanner page (#319);
// and both show "2 already in cart". The scan also names the real store in its
// out-of-stock message, wired from the POS controller.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/providers/pos_providers.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';

import '../helpers/fake_barcode_scanner.dart';
import '../helpers/pos_home_harness.dart';
import '../helpers/viewports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosTestEnvironment env;

  setUp(() async {
    env = await setupTestPosEnvironment(productCount: 2);
    AppNotification.hide();
  });

  tearDown(() async {
    await env.dispose();
  });

  Future<void> setBarcode(String productId, String barcode) {
    return (env.db.update(env.db.products)
          ..where((t) => t.id.equals(productId)))
        .write(ProductsCompanion(barcode: Value(barcode)));
  }

  String qtyText(WidgetTester tester) => tester
      .widget<TextField>(
        find
            .descendant(
              of: find.byType(EditItemModal),
              matching: find.byType(TextField),
            )
            .first,
      )
      .controller!
      .text;

  Future<void> closeSheet(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('hold opens on the cart total, a scan on one more — both say '
      '"2 already in cart"', (tester) async {
    final product = env.products.first;
    await setBarcode(product.id, 'BC-1');
    final scanner = FakeBarcodeScanner();

    final harness = await pumpPosHome(
      tester,
      env: env,
      size: pixel7Portrait,
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
        barcodeScannerProvider.overrideWithValue(scanner),
      ],
    );
    final cart = ProviderScope.containerOf(harness.context).read(cartProvider);
    cart.addItem(product, qty: 2, maxStock: 50, tier: PriceTier.retailer);
    await tester.pumpAndSettle();

    // Tap-and-hold: starts on the cart total.
    await tester.longPress(find.byKey(posProductTileKey(product.id)));
    await tester.pumpAndSettle();
    expect(find.byType(EditItemModal), findsOneWidget);
    expect(qtyText(tester), '2');
    expect(find.text('2 already in cart'), findsOneWidget);
    await closeSheet(tester);

    // Scan: starts one above the cart total.
    await tester.tap(find.byKey(kPosScannerKey));
    await tester.pumpAndSettle();
    scanner.camera!.read('BC-1');
    await tester.pumpAndSettle();
    expect(find.byType(EditItemModal), findsOneWidget);
    expect(qtyText(tester), '3');
    expect(find.text('2 already in cart'), findsOneWidget);
    await closeSheet(tester);

    // Neither sheet changed the cart.
    expect(cart.value.single['qty'], 2);

    await disposePosHome(tester);
  });

  testWidgets('hold on a product not in the cart starts on 1 with no '
      '"already in cart" line', (tester) async {
    final product = env.products.first;
    await pumpPosHome(
      tester,
      env: env,
      size: pixel7Portrait,
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
    );

    await tester.longPress(find.byKey(posProductTileKey(product.id)));
    await tester.pumpAndSettle();
    expect(qtyText(tester), '1');
    expect(find.textContaining('already in cart'), findsNothing);
    await closeSheet(tester);

    await disposePosHome(tester);
  });

  testWidgets('a scan of a product with no stock here names the active store', (
    tester,
  ) async {
    final product = env.products.first;
    await setBarcode(product.id, 'BC-1');
    await (env.db.update(env.db.inventory)
          ..where((t) => t.productId.equals(product.id)))
        .write(const InventoryCompanion(quantity: Value(0)));
    final scanner = FakeBarcodeScanner();

    await pumpPosHome(
      tester,
      env: env,
      size: pixel7Portrait,
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
        barcodeScannerProvider.overrideWithValue(scanner),
      ],
    );

    await tester.tap(find.byKey(kPosScannerKey));
    await tester.pumpAndSettle();
    scanner.camera!.read('BC-1');
    await tester.pumpAndSettle();

    expect(find.byType(EditItemModal), findsNothing);
    expect(
      find.text('${product.name} is out of stock at Main Store'),
      findsOneWidget,
    );

    AppNotification.hide();
    await tester.pumpAndSettle();
    await disposePosHome(tester);
  });
}
