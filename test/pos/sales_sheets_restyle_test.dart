// Behaviour and layout tests for the Wave 2 A sales-sheet restyle (#393):
// Checkout, Edit Item / Add to Cart, Quick Sale, the scan sheets, the camera
// sheet and the Cart's Select Customer / Saved Carts sheets. Every control
// renders, the main actions still work, permission-hidden controls stay
// hidden, and nothing overflows at 360dp @1.3, 390×844, 844×390 with insets,
// 800×1280 and 1280×800, or with the keyboard up in a form. Money is pinned
// separately by `checkout_money_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/settings/screens/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';
import 'package:reebaplus_pos/features/pos/widgets/cart/cart_parts.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/quick_sale_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_unknown_choice_sheet.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_which_one_sheet.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/screen_harness.dart';
import 'cart_sheet_fixture.dart';
import 'checkout_fixture.dart';
import 'sales_sheet_hosts.dart';

/// The layouts every screen and sheet must fit (realistic insets).
final _layouts = <String, ({Size size, EdgeInsets padding, TextScaler? scale})>{
  '360x800 @1.3': (
    size: const Size(360, 800),
    padding: const EdgeInsets.only(top: 24, bottom: 48),
    scale: const TextScaler.linear(1.3),
  ),
  '390x844 3-button': (
    size: const Size(390, 844),
    padding: const EdgeInsets.only(top: 24, bottom: 48),
    scale: null,
  ),
  '390x844 gesture': (
    size: const Size(390, 844),
    padding: const EdgeInsets.only(top: 24, bottom: 24),
    scale: null,
  ),
  '844x390 insets': (
    size: const Size(844, 390),
    padding: const EdgeInsets.only(top: 24, right: 48),
    scale: null,
  ),
  '800x1280': (
    size: const Size(800, 1280),
    padding: const EdgeInsets.only(top: 24, bottom: 24),
    scale: null,
  ),
  '1280x800': (
    size: const Size(1280, 800),
    padding: const EdgeInsets.only(top: 24),
    scale: null,
  ),
};

/// Keyboard-up cases: an upright phone (300dp keyboard) and a sideways one.
final _keyboards =
    <String, ({Size size, EdgeInsets padding, EdgeInsets keyboard})>{
      '390x844 keyboard': (
        size: const Size(390, 844),
        padding: const EdgeInsets.only(top: 24),
        keyboard: const EdgeInsets.only(bottom: 300),
      ),
      '844x390 keyboard': (
        size: const Size(844, 390),
        padding: const EdgeInsets.only(top: 24, right: 48),
        keyboard: const EdgeInsets.only(bottom: 180),
      ),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  /// Lets every toast run out before the tree is disposed.
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  double heightOf(WidgetTester tester, Finder f) => tester.getSize(f).height;

  group('Checkout', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(businessType: 'Bar');
    });
    tearDown(() async => env.dispose());

    testWidgets('renders every control for a registered customer', (
      tester,
    ) async {
      await pumpCheckout(
        tester,
        env: env,
        size: const Size(800, 1280),
        customer: checkoutCustomer,
        creditKobo: 500000,
        crates: true,
      );
      expect(find.text('Checkout'), findsOneWidget);
      for (final key in [
        CheckoutKeys.topBar,
        CheckoutKeys.summary,
        CheckoutKeys.crateValueMissing,
        CheckoutKeys.crateDeposit,
        CheckoutKeys.depositRow('mfr-nb'),
        CheckoutKeys.depositRow('mfr-hero'),
        CheckoutKeys.customer,
        CheckoutKeys.modeCash,
        CheckoutKeys.modeWallet,
        CheckoutKeys.modeCredit,
        CheckoutKeys.tenderCash,
        CheckoutKeys.tenderTransfer,
        CheckoutKeys.amountPaid,
        CheckoutKeys.autoFill,
        CheckoutKeys.creditInfo,
        CheckoutKeys.confirm,
      ]) {
        await tester.scrollUntilVisible(
          find.byKey(key),
          200,
          scrollable: find
              .descendant(
                of: find.byKey(CheckoutKeys.form),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.byKey(key), findsOneWidget, reason: '$key');
      }
      await finish(tester);
    });

    testWidgets('walk-in: no Pay with Credit, Credit Sale or credit info; '
        'crates read-only', (tester) async {
      await pumpCheckout(
        tester,
        env: env,
        size: const Size(800, 1280),
        crates: true,
      );
      expect(find.byKey(CheckoutKeys.modeCash), findsOneWidget);
      expect(find.byKey(CheckoutKeys.modeWallet), findsNothing);
      expect(find.byKey(CheckoutKeys.modeCredit), findsNothing);
      expect(find.byKey(CheckoutKeys.creditInfo), findsNothing);
      expect(find.byKey(CheckoutKeys.crateDeposit), findsNothing);
      expect(find.byKey(CheckoutKeys.cratesTaken), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Auto-fill fills total − credit; Pay with Credit shows the '
        'balances; the credit-info card toggles', (tester) async {
      await pumpCheckout(
        tester,
        env: env,
        size: const Size(800, 1280),
        customer: checkoutCustomer,
        creditKobo: 500000,
      );
      await tester.tap(find.byKey(CheckoutKeys.autoFill));
      await tester.pump();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(CheckoutKeys.amountPaid),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, '27,500');

      await tester.tap(find.byKey(CheckoutKeys.modeWallet));
      await tester.pump();
      expect(find.text('Credits Balance'), findsOneWidget);
      expect(find.byKey(CheckoutKeys.amountPaid), findsNothing);

      final info = find.byKey(CheckoutKeys.creditInfo);
      await tester.ensureVisible(info);
      await tester.pump();
      Finder boxIcon(IconData icon) =>
          find.descendant(of: info, matching: find.byIcon(icon));
      expect(boxIcon(AppIcons.checkBoxOutlineBlank), findsOneWidget);
      await tester.tap(info);
      await tester.pump();
      expect(boxIcon(AppIcons.checkBox), findsOneWidget);
      await finish(tester);
    });

    testWidgets('payment controls are at least 48dp tall', (tester) async {
      await pumpCheckout(
        tester,
        env: env,
        customer: checkoutCustomer,
        creditKobo: 500000,
        crates: true,
      );
      for (final key in [
        CheckoutKeys.depositRow('mfr-nb'),
        CheckoutKeys.modeCash,
        CheckoutKeys.modeWallet,
        CheckoutKeys.modeCredit,
        CheckoutKeys.tenderCash,
        CheckoutKeys.tenderTransfer,
        CheckoutKeys.autoFill,
        CheckoutKeys.creditInfo,
      ]) {
        await tester.ensureVisible(find.byKey(key));
        await tester.pump();
        expect(
          heightOf(tester, find.byKey(key)),
          greaterThanOrEqualTo(kMinInteractiveDimension),
          reason: '$key',
        );
      }
      await finish(tester);
    });

    testWidgets('caps the form at 720 on a wide screen', (tester) async {
      await pumpCheckout(
        tester,
        env: env,
        size: const Size(1280, 800),
        padding: const EdgeInsets.only(top: 24),
        customer: checkoutCustomer,
      );
      expect(
        tester.getSize(find.byKey(CheckoutKeys.summary)).width,
        lessThanOrEqualTo(kSettingsMaxContentWidth),
      );
      await finish(tester);
    });

    for (final MapEntry(key: name, value: l) in _layouts.entries) {
      testWidgets('no overflow at $name', (tester) async {
        await pumpCheckout(
          tester,
          env: env,
          size: l.size,
          padding: l.padding,
          textScaler: l.scale,
          customer: checkoutCustomer,
          creditKobo: 500000,
          crates: true,
        );
        expectNoOverflow(tester, reason: name);
        final confirm = find.byKey(CheckoutKeys.confirm);
        await tester.scrollUntilVisible(
          confirm,
          300,
          scrollable: find
              .descendant(
                of: find.byKey(CheckoutKeys.form),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          tester.getRect(confirm).bottom,
          lessThanOrEqualTo(l.size.height),
        );
        expectNoOverflow(tester, reason: name);
        await finish(tester);
      });
    }

    for (final MapEntry(key: name, value: k) in _keyboards.entries) {
      testWidgets('no overflow with the $name (amount + deposit sheet)', (
        tester,
      ) async {
        await pumpCheckout(
          tester,
          env: env,
          size: k.size,
          padding: k.padding,
          viewInsets: k.keyboard,
          customer: checkoutCustomer,
          creditKobo: 500000,
          crates: true,
        );
        expectNoOverflow(tester, reason: name);
        final row = find.byKey(CheckoutKeys.depositRow('mfr-nb'));
        await tester.ensureVisible(row);
        await tester.pump();
        await tester.tap(row);
        await settleCheckout(tester);
        expect(find.byKey(CheckoutKeys.depositSheet), findsOneWidget);
        expectNoOverflow(tester, reason: '$name deposit sheet');
        await finish(tester);
      });
    }
  });

  group('sales sheets', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(productCount: 2);
    });
    tearDown(() async => env.dispose());

    testWidgets('Edit Item: steppers change the quantity; Save keeps working', (
      tester,
    ) async {
      await pumpSheet(tester, env: env, sheet: SalesSheet.editItem);
      expect(find.text('Edit Quantity'), findsOneWidget);
      expect(find.text('CUSTOM PRICE'), findsOneWidget);
      expect(find.text('APPLY DISCOUNT'), findsOneWidget);
      final qty = find.descendant(
        of: find.byKey(EditItemKeys.quantity),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(qty).controller!.text, '2.0');
      await tester.tap(find.byKey(EditItemKeys.plus));
      await tester.pump();
      expect(tester.widget<TextField>(qty).controller!.text, '3');
      await tester.tap(find.byKey(EditItemKeys.minus));
      await tester.pump();
      expect(tester.widget<TextField>(qty).controller!.text, '2');
      for (final key in [
        EditItemKeys.plus,
        EditItemKeys.minus,
        EditItemKeys.close,
        EditItemKeys.kind('percent'),
        EditItemKeys.kind('naira'),
      ]) {
        expect(
          heightOf(tester, find.byKey(key)),
          greaterThanOrEqualTo(kMinInteractiveDimension),
          reason: '$key',
        );
      }
      await tester.tap(find.text('Save Changes'));
      await settleSheet(tester);
      expect(find.byKey(EditItemKeys.sheet), findsNothing);
      await finish(tester);
    });

    testWidgets('Edit Item: no discount role → blocked note; no custom-price '
        'grant → no custom price', (tester) async {
      await pumpSheet(
        tester,
        env: env,
        sheet: SalesSheet.editItem,
        maxDiscountPercent: 0,
        grantedKeys: const {'sales.make'},
      );
      expect(find.byKey(EditItemKeys.discountBlocked), findsOneWidget);
      expect(find.text('APPLY DISCOUNT'), findsNothing);
      expect(find.text('CUSTOM PRICE'), findsNothing);
      await finish(tester);
    });

    testWidgets('Add to Cart: shows the stock cap and adds the line', (
      tester,
    ) async {
      await pumpSheet(tester, env: env, sheet: SalesSheet.addToCart);
      expect(find.text('Add to Cart'), findsWidgets);
      expect(
        find.text('50 in stock — quantity can\'t exceed this'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(AppButton, 'Add to Cart'));
      await settleSheet(tester);
      expect(find.byKey(EditItemKeys.sheet), findsNothing);
      await finish(tester);
    });

    testWidgets('Quick Sale: the approval note shows only when approval is '
        'needed', (tester) async {
      await pumpSheet(tester, env: env, sheet: SalesSheet.quickSale);
      expect(find.byKey(QuickSaleKeys.dialog), findsOneWidget);
      expect(find.text('Send to Cart'), findsOneWidget);
      expect(find.byKey(QuickSaleKeys.approvalNote), findsNothing);
      await finish(tester);

      await pumpSheet(tester, env: env, sheet: SalesSheet.quickSaleApproval);
      expect(find.text('Send for Approval'), findsOneWidget);
      expect(find.byKey(QuickSaleKeys.approvalNote), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Quick Sale caps its width on a wide screen', (tester) async {
      await pumpSheet(
        tester,
        env: env,
        sheet: SalesSheet.quickSale,
        size: const Size(1280, 800),
        padding: const EdgeInsets.only(top: 24),
      );
      expect(
        tester
            .getSize(
              find
                  .descendant(
                    of: find.byKey(QuickSaleKeys.dialog),
                    matching: find.byType(Column),
                  )
                  .first,
            )
            .width,
        lessThanOrEqualTo(kQuickSaleMaxWidth),
      );
      await finish(tester);
    });

    testWidgets('Which one: every row shows and picks', (tester) async {
      await pumpSheet(tester, env: env, sheet: SalesSheet.scanWhichOne);
      expect(find.text('Which one?'), findsOneWidget);
      final row = find.byKey(
        ValueKey<String>('$kScanChoiceKeyPrefix${env.products[0].id}'),
      );
      expect(heightOf(tester, row), greaterThanOrEqualTo(48));
      expect(find.textContaining('Out of stock'), findsOneWidget);
      await tester.tap(row);
      await settleSheet(tester);
      expect(find.byType(ScanWhichOneSheet), findsNothing);
      await finish(tester);
    });

    testWidgets('New barcode: both options with both gates; the link option '
        'hides without it', (tester) async {
      await pumpSheet(tester, env: env, sheet: SalesSheet.scanUnknownChoice);
      expect(find.byKey(kScanUnknownAddNewKey), findsOneWidget);
      expect(find.byKey(kScanUnknownLinkKey), findsOneWidget);
      await finish(tester);

      await pumpSheet(tester, env: env, sheet: SalesSheet.scanUnknownAddOnly);
      expect(find.byKey(kScanUnknownAddNewKey), findsOneWidget);
      expect(find.byKey(kScanUnknownLinkKey), findsNothing);
      await finish(tester);
    });

    testWidgets('Link to a product: search field and results', (tester) async {
      await pumpSheet(tester, env: env, sheet: SalesSheet.scanLinkProduct);
      expect(find.text('Link to a product'), findsOneWidget);
      expect(find.byType(AppInput), findsOneWidget);
      expect(find.text('Product 1'), findsOneWidget);
      await finish(tester);
    });

    const sheets = [
      SalesSheet.editItem,
      SalesSheet.addToCart,
      SalesSheet.quickSaleApproval,
      SalesSheet.scanWhichOne,
      SalesSheet.scanUnknownChoice,
      SalesSheet.scanLinkProduct,
      SalesSheet.cameraPermission,
    ];
    for (final MapEntry(key: name, value: l) in _layouts.entries) {
      testWidgets('no sheet overflows at $name', (tester) async {
        for (final sheet in sheets) {
          await pumpSheet(
            tester,
            env: env,
            sheet: sheet,
            size: l.size,
            padding: l.padding,
            textScaler: l.scale,
          );
          expectNoOverflow(tester, reason: '$sheet at $name');
          await finish(tester);
        }
      });
    }

    const forms = [
      SalesSheet.editItem,
      SalesSheet.addToCart,
      SalesSheet.quickSale,
      SalesSheet.scanLinkProduct,
    ];
    for (final MapEntry(key: name, value: k) in _keyboards.entries) {
      testWidgets('no form sheet overflows with the $name', (tester) async {
        for (final sheet in forms) {
          await pumpSheet(
            tester,
            env: env,
            sheet: sheet,
            size: k.size,
            padding: k.padding,
            viewInsets: k.keyboard,
          );
          expectNoOverflow(tester, reason: '$sheet with $name');
          await finish(tester);
        }
      });
    }
  });

  group('Cart sheets', () {
    late List<String> ids;
    setUp(() async {
      env = await setupScreenTestEnvironment();
      ids = await seedCartSheetData(env);
    });
    tearDown(() async => env.dispose());

    Future<void> open(WidgetTester tester, Key opener) async {
      final button = find.byKey(opener);
      if (button.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          button,
          200,
          scrollable: find.byType(Scrollable).first,
        );
      }
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await settleCartSheets(tester);
    }

    testWidgets('Select Customer: walk-in + customers with balances; picking '
        'one sets the cart customer', (tester) async {
      await pumpCartForSheets(tester, env: env, ids: ids);
      await open(tester, CartKeys.change);
      expect(find.byKey(const Key('cart-customer-picker')), findsOneWidget);
      expect(find.byKey(const Key('cart-picker-new')), findsOneWidget);
      expect(find.text('Walk-in Customer'), findsWidgets);
      expect(find.text('Bal: ${formatCurrency(-12500)}'), findsOneWidget);
      expect(find.text('Bal: ${formatCurrency(3000)}'), findsOneWidget);
      final row = find.byKey(Key('cart-picker-row-${ids[0]}'));
      expect(heightOf(tester, row), greaterThanOrEqualTo(48));
      await tester.tap(row);
      await settleCartSheets(tester);
      expect(find.byKey(const Key('cart-customer-picker')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(CartKeys.customerCard),
          matching: find.text('Chinedu Okafor'),
        ),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('Select Customer: New is hidden without customers.add', (
      tester,
    ) async {
      await pumpCartForSheets(
        tester,
        env: env,
        ids: ids,
        grantedKeys: const {'sales.make'},
      );
      await open(tester, CartKeys.change);
      expect(find.byKey(const Key('cart-customer-picker')), findsOneWidget);
      expect(find.byKey(const Key('cart-picker-new')), findsNothing);
      await finish(tester);
    });

    testWidgets('Saved Carts: lists the saved carts; delete removes one', (
      tester,
    ) async {
      await pumpCartForSheets(tester, env: env, ids: ids);
      await open(tester, CartKeys.recall);
      expect(find.byKey(const Key('cart-saved-carts-sheet')), findsOneWidget);
      expect(find.text('Morning Order'), findsOneWidget);
      expect(find.text('Bar restock'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete').first);
      await settleCartSheets(tester);
      expect(find.text('Bar restock'), findsNothing);
      await finish(tester);
    });

    for (final MapEntry(key: name, value: l) in _layouts.entries) {
      testWidgets('no overflow in either Cart sheet at $name', (tester) async {
        for (final opener in [CartKeys.change, CartKeys.recall]) {
          await pumpCartForSheets(
            tester,
            env: env,
            ids: ids,
            size: l.size,
            padding: l.padding,
            textScaler: l.scale,
          );
          await open(tester, opener);
          expectNoOverflow(tester, reason: '$opener at $name');
          await finish(tester);
        }
      });
    }

    for (final MapEntry(key: name, value: k) in _keyboards.entries) {
      testWidgets('Select Customer fits with the $name', (tester) async {
        await pumpCartForSheets(
          tester,
          env: env,
          ids: ids,
          size: k.size,
          padding: k.padding,
          viewInsets: k.keyboard,
        );
        await open(tester, CartKeys.change);
        expectNoOverflow(tester, reason: name);
        await finish(tester);
      });
    }
  });
}
