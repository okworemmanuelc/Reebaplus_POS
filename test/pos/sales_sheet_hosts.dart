// Hosts the restyled sales sheets (#393) for tests and goldens: a plain screen
// with an "open" button that raises the sheet on the screen's navigator, as
// POS / the Cart / the scanner do. Sample data only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scan_resolver.dart';
import 'package:reebaplus_pos/features/pos/widgets/camera_permission_sheet.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/quick_sale_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_link_product_sheet.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_unknown_choice_sheet.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_which_one_sheet.dart';

import '../helpers/screen_harness.dart';

/// The sheets this file can raise.
enum SalesSheet {
  editItem,
  addToCart,
  quickSale,
  quickSaleApproval,
  scanWhichOne,
  scanUnknownChoice,
  scanUnknownAddOnly,
  scanLinkProduct,
  cameraPermission,
}

const kOpenSheetKey = Key('test-open-sheet');

/// A cart line as the Cart holds it: Star Lager ×2 at ₦9,600, 50 in stock.
Map<String, dynamic> editItemLine() => {
  'name': 'Star Lager',
  'qty': 2.0,
  'price': 9600.0,
  'unitPriceKobo': 960000,
  'catalogPriceKobo': 960000,
  'customPriceKobo': null,
  'discountKind': null,
  'discountValue': 0.0,
  'maxStock': 50,
  'allowFractionalSales': false,
};

Future<void> _open(
  BuildContext context,
  SalesSheet sheet,
  List<ProductData> products,
) {
  switch (sheet) {
    case SalesSheet.editItem:
      return EditItemModal.show(context, editItemLine());
    case SalesSheet.addToCart:
      return EditItemModal.showForProduct(
        context,
        product: products.first,
        maxStock: 50,
        tier: PriceTier.retailer,
      );
    case SalesSheet.quickSale:
    case SalesSheet.quickSaleApproval:
      final t = Theme.of(context);
      return showDialog(
        context: context,
        builder: (_) => QuickSaleModal(
          surfaceCol: t.colorScheme.surface,
          textCol: t.colorScheme.onSurface,
          subtextCol: t.colorScheme.onSurface,
          cardCol: t.cardColor,
          isDark: t.brightness == Brightness.dark,
          requireApproval: sheet == SalesSheet.quickSaleApproval,
        ),
      );
    case SalesSheet.scanWhichOne:
      return ScanWhichOneSheet.show(
        context,
        choices: [
          ScanChoice(
            product: products[0],
            unitPriceKobo: 960000,
            stock: 50,
            outcome: ScanAddSheet(
              product: products[0],
              stock: 50,
              inCart: 0,
              tier: PriceTier.retailer,
            ),
          ),
          ScanChoice(
            product: products[1],
            unitPriceKobo: 840000,
            stock: 0,
            outcome: ScanOutOfStockHere(product: products[1]),
          ),
        ],
      );
    case SalesSheet.scanUnknownChoice:
      return ScanUnknownChoiceSheet.show(
        context,
        code: '6151100012345',
        canAdd: true,
        canLink: true,
      );
    case SalesSheet.scanUnknownAddOnly:
      return ScanUnknownChoiceSheet.show(
        context,
        code: '6151100012345',
        canAdd: true,
        canLink: false,
      );
    case SalesSheet.scanLinkProduct:
      return ScanLinkProductSheet.show(context, code: '6151100012345');
    case SalesSheet.cameraPermission:
      return CameraPermissionSheet.show(context);
  }
}

/// Pumps a host screen at [size], opens [sheet] and settles. Under 600dp the
/// host sits above a bottom bar (a tab root), at 600dp+ beside the rail.
Future<void> pumpSheet(
  WidgetTester tester, {
  required ScreenTestEnvironment env,
  required SalesSheet sheet,
  Size size = const Size(390, 844),
  EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 48),
  EdgeInsets viewInsets = EdgeInsets.zero,
  TextScaler? textScaler,
  Brightness brightness = Brightness.light,
  int maxDiscountPercent = 20,
  Set<String> grantedKeys = const {'sales.make', 'sales.set_custom_price'},
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
    overrides: [
      currentUserMaxDiscountPercentProvider.overrideWithValue(
        maxDiscountPercent,
      ),
    ],
    screen: Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => TextButton(
            key: kOpenSheetKey,
            onPressed: () => _open(context, sheet, env.products),
            child: const Text('open'),
          ),
        ),
      ),
    ),
    settle: false,
  );
  await settleSheet(tester);
  await tester.tap(find.byKey(kOpenSheetKey));
  await settleSheet(tester);
}

Future<void> settleSheet(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// Drops the keyboard focus so a golden shows no caret.
Future<void> unfocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await settleSheet(tester);
}
