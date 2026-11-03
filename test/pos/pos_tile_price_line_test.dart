// #641: the POS tile shows the price on its own line (never shrunk for 4-6
// figure prices) with the stock pill below, and "size · unit" under the name.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

ProductData _product({String? unit, String? size, String? subtitle}) =>
    ProductData(
      id: 'p1',
      businessId: 'b1',
      name: 'Heineken',
      unit: unit,
      size: size,
      subtitle: subtitle,
      buyingPriceKobo: 5000,
      retailerPriceKobo: 10000,
      wholesalerPriceKobo: 9000,
      isAvailable: true,
      showOnline: true,
      minOrderQty: 1,
      orderStep: 1,
      isDeleted: false,
      lowStockThreshold: 0,
      avgDailySales: 0,
      leadTimeDays: 0,
      safetyStockQty: 0,
      monthlyTargetUnits: 0,
      emptyCrateValueKobo: 0,
      trackEmpties: false,
      allowFractionalSales: false,
      version: 1,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('posTileSubtitle', () {
    // #675: the size lives in the name, so only the unit shows; a Bottle
    // reads "Bottle" in every shop.
    test('the unit only, never the stored size', () {
      expect(
        posTileSubtitle(
          _product(unit: 'Bottle', size: 'big', subtitle: 'Lager'),
        ),
        'Bottle',
      );
      expect(posTileSubtitle(_product(unit: 'Can')), 'Can');
    });
    test('no unit (description and size are not shown)', () {
      expect(posTileSubtitle(_product(size: 'big')), isNull);
      expect(posTileSubtitle(_product(subtitle: 'Lager')), isNull);
    });
  });

  Future<void> pump(
    WidgetTester tester, {
    double tileWidth = 100,
    double textScale = 1.0,
    required List<String> prices,
    String subtitle = '60cl · Bottle Crate',
  }) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: Wrap(
                children: [
                  for (final p in prices)
                    SizedBox(
                      width: tileWidth,
                      height: 230,
                      child: ProductTile(
                        name: 'Heineken',
                        subtitle: subtitle,
                        subtitleMaxLines: 2,
                        priceLabel: p,
                        stockLabel: '38',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('price up to 6 figures is not scaled down; pill sits below', (
    tester,
  ) async {
    await pump(tester, prices: ['₦400', '₦13,500', '₦100,000']);
    double scaleOf(String s) {
      final text = tester.renderObject<RenderBox>(find.text(s));
      final fitted = tester.renderObject<RenderBox>(
        find.ancestor(of: find.text(s), matching: find.byType(FittedBox)),
      );
      return fitted.size.width >= text.size.width
          ? 1.0
          : fitted.size.width / text.size.width;
    }

    expect(scaleOf('₦400'), 1.0);
    expect(scaleOf('₦13,500'), 1.0);
    expect(scaleOf('₦100,000'), 1.0);
    final priceBottom = tester.getBottomLeft(find.text('₦13,500')).dy;
    final pillTop = tester.getTopLeft(find.text('38').first).dy;
    expect(pillTop, greaterThan(priceBottom - 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Bottle Crate" is fully visible at 360dp, text scale 1.3', (
    tester,
  ) async {
    await pump(tester, tileWidth: 360 / 3, textScale: 1.3, prices: ['₦13,500']);
    final render = tester.renderObject<RenderParagraph>(
      find.text('60cl · Bottle Crate'),
    );
    expect(render.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });
}
