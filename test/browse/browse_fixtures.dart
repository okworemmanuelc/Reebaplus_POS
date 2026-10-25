import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_providers.dart';
import 'package:reebaplus_pos/core/storefront/storefront_service.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';

const kTestArea = ShopperArea(state: 'Nasarawa', lga: 'Keffi');

Map<String, Object?> cardRow({
  required String id,
  required String name,
  String store = 'store-1',
  String business = 'Stallion Global',
  String lga = 'Nasarawa',
  String stock = 'in_stock',
  int? onlyLeft,
  int price = 450000,
  String? unit = 'Crate',
  int? pack = 12,
  String category = 'beer',
  int? deposit,
  bool age = false,
  bool stale = false,
  String? brand,
  String? description,
  int minQty = 1,
  int step = 1,
  int? maxQty,
}) => {
  'product_id': id,
  'store_id': store,
  'name': name,
  'image_url': null,
  'unit': unit,
  'units_per_pack': pack,
  'category': category,
  'price_kobo': price,
  'currency': 'NGN',
  'crate_deposit_kobo': deposit,
  'stock_label': stock,
  'only_left': onlyLeft,
  'age_restricted': age,
  'stock_may_be_stale': stale,
  'business_name': business,
  'store_lga': lga,
  'online_description': description,
  'brand': brand,
  'min_order_qty': minQty,
  'order_step': step,
  'max_order_qty': maxQty,
  'sponsored': false,
  'cursor': '0:0:0:0:-1:$id',
};

final kFeedRows = [
  cardRow(id: 'p1', name: 'Star Lager', deposit: 150000, age: true,
      brand: 'Nigerian Breweries', description: 'Chilled on request. 60cl returnable bottles.',
      minQty: 2, step: 2, maxQty: 20),
  cardRow(id: 'p2', name: 'Eva Water 75cl', category: 'water', stock: 'low_stock',
      price: 120000, unit: 'Pack', pack: 12, business: 'Keffi Drinks', lga: 'Keffi',
      store: 'store-2'),
  cardRow(id: 'p3', name: 'Coca-Cola 50cl', category: 'soft-drinks',
      stock: 'only_few_left', onlyLeft: 2, unit: 'PET', pack: 12, stale: true),
  cardRow(id: 'p4', name: 'Hero Lager', stock: 'in_stock', price: 380000),
];

final kSearchRows = [
  cardRow(id: 'p1', name: 'Star Lager', deposit: 150000, age: true),
  cardRow(id: 'p5', name: 'Star Radler', stock: 'out_of_stock'),
];

final kStoreRow = <String, Object?>{
  'store_id': 'store-9',
  'business_name': 'Far Away Ventures',
  'logo_url': null,
  'store_state': 'Lagos',
  'store_lga': 'Ikeja',
  'online_note': 'Delivery Mon–Sat. ₦500 delivery fee.',
  'currency': 'NGN',
  'delivers_to_area': false,
  'stock_may_be_stale': false,
};

/// A fake storefront backend recording every call.
class FakeStorefront {
  FakeStorefront({this.online = true});

  bool online;
  final calls = <(String, Map<String, Object?>)>[];
  List<Map<String, Object?>> feed = kFeedRows;
  List<Map<String, Object?>> search = kSearchRows;
  List<Map<String, Object?>> store = [kStoreRow];
  List<Map<String, Object?>> storeProducts = kSearchRows;

  late final service = StorefrontService.withRpc(
    isOnline: () async => online,
    rpc: (fn, params) async {
      calls.add((fn, params));
      return switch (fn) {
        'storefront_feed' => feed,
        'storefront_search' => search,
        'storefront_store' => store,
        'storefront_store_products' => storeProducts,
        _ => throw StateError('unexpected $fn'),
      };
    },
  );
}

Future<void> pumpBrowse(
  WidgetTester tester, {
  required Widget screen,
  required FakeStorefront backend,
  ShopperArea? area = kTestArea,
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  SharedPreferences.setMockInitialValues({
    if (area != null)
      ShopperAreaNotifier.prefKey: jsonEncode(area.toJson()),
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  if (padding != EdgeInsets.zero) {
    tester.view.padding = FakeViewPadding(
      top: padding.top, right: padding.right, left: padding.left);
    tester.view.viewPadding = FakeViewPadding(
      top: padding.top, right: padding.right, left: padding.left);
  }
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storefrontServiceProvider.overrideWithValue(backend.service)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
            ),
            child: screen,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
