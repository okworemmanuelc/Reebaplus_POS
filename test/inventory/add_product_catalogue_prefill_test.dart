// add_product_catalogue_prefill_test.dart
//
// #332 (PRD #322, ADR 0029 §8) — Add Product fills in empty boxes from the
// shared barcode catalogue. A fake BarcodeCatalogueService stands in for the
// network; a recording ProductImageService stands in for Storage on save.

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/barcode_catalogue_service.dart';
import 'package:reebaplus_pos/core/services/barcode_suggestion.dart';
import 'package:reebaplus_pos/core/services/catalogue_lookup.dart';
import 'package:reebaplus_pos/core/services/catalogue_report.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_filled_note.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_photo_field.dart';
import 'package:reebaplus_pos/features/inventory/widgets/update_product_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// A real factory GTIN (EAN-13, Nigeria prefix 615) and a second one.
const _gtin = '6150001234561';
const _otherGtin = '5000112637922';

/// Records every lookup. Answers with [answer], or with [pending] when set
/// (a late answer the test completes by hand).
class _FakeCatalogue implements BarcodeCatalogueService {
  final calls = <String>[];

  /// The includePhoto flag of each call, in order.
  final photoAsked = <bool>[];
  BarcodeSuggestion? answer;
  Completer<BarcodeSuggestion?>? pending;

  @override
  Duration get timeout => BarcodeCatalogueService.defaultTimeout;

  @override
  Future<BarcodeSuggestion?> lookup(String code, {bool includePhoto = true}) {
    calls.add(code);
    photoAsked.add(includePhoto);
    return pending?.future ?? Future.value(answer);
  }

  // Report sheet methods (#335): Add Product never calls them.
  @override
  Future<CatalogueLookup> lookupOutcome(
    String code, {
    bool includePhoto = true,
  }) => throw UnimplementedError();

  @override
  Future<CatalogueReportResult> report({
    required String businessId,
    required String barcode,
    required Set<CatalogueReportReason> reasons,
    String? note,
    String? shownName,
    String? shownUnit,
    String? shownPhotoUrl,
  }) => throw UnimplementedError();
}

/// Real photo processing ([processBytes] is inherited); [save] records what
/// would go to the shop's own Storage folder instead of uploading.
class _RecordingImageService extends ProductImageService {
  _RecordingImageService() : super(Supabase.instance.client);

  final saved = <({String businessId, String productId, Uint8List bytes})>[];

  @override
  Future<Result<String, AppError>> save({
    required String businessId,
    required String productId,
    required Uint8List bytes,
  }) async {
    saved.add((businessId: businessId, productId: productId, bytes: bytes));
    return Result.ok('https://example.test/$businessId/$productId.jpg');
  }
}

/// A 1000×500 PNG: bigger than the 800 px cap, so processing must shrink it.
final Uint8List _bigPhoto = Uint8List.fromList(
  img.encodePng(img.Image(width: 1000, height: 500)),
);

void main() {
  late AppDatabase db;
  late _FakeCatalogue catalogue;
  late _RecordingImageService images;
  const businessId = 'biz-1';
  const userId = 'user-1';
  const storeId = 'store-1';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  Future<void> seed({String type = 'supermarket'}) async {
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Biz',
            type: Value(type),
          ),
        );
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'Test User',
            pin: '0000',
            avatarColor: const Value('#3B82F6'),
            biometricEnabled: const Value(false),
          ),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: const Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: const Value('prod-coke'),
            businessId: businessId,
            name: 'Coke 50cl',
            retailerPriceKobo: const Value(30000),
            wholesalerPriceKobo: const Value(28000),
          ),
        );
  }

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;
    catalogue = _FakeCatalogue();
    images = _RecordingImageService();
  });

  tearDown(() => db.close());

  Future<ProviderContainer> pumpWidgetUnder(
    WidgetTester tester,
    Widget home,
  ) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        barcodeCatalogueServiceProvider.overrideWithValue(catalogue),
        productImageServiceProvider.overrideWithValue(images),
        currentUserPermissionsProvider.overrideWithValue({
          'products.edit_buying_price',
          'products.edit_price',
          'products.add',
          'stock.add',
        }),
      ],
    );
    addTearDown(container.dispose);
    // Keeps the active business loaded, as MainLayout does in the app, so the
    // screen's crate-business check and lexicon see it.
    container.listen(currentBusinessProvider, (_, _) {});
    container.read(authProvider).value = await db.storesDao.getUserById(
      userId,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    String? prefilledBarcode,
    bool receiveMode = false,
  }) => pumpWidgetUnder(
    tester,
    AddProductScreen(
      prefilledBarcode: prefilledBarcode,
      receiveMode: receiveMode,
    ),
  );

  Finder fieldFor(String labelPart) => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is AppInput && (w.labelText?.contains(labelPart) ?? false),
    ),
    matching: find.byType(TextFormField),
  );

  String textOf(WidgetTester tester, String labelPart) =>
      tester.widget<TextFormField>(fieldFor(labelPart)).controller!.text;

  AppDropdown<String?> unitDropdown(WidgetTester tester) =>
      tester.widget<AppDropdown<String?>>(find.byType(AppDropdown<String?>));

  List<String?> unitOptions(WidgetTester tester) =>
      unitDropdown(tester).items.map((i) => i.value).toList();

  Future<void> openMoreDetails(WidgetTester tester) async {
    if (fieldFor('Barcode').evaluate().isNotEmpty) return;
    final header = find.text('More details');
    await tester.ensureVisible(header);
    await tester.tap(header);
    await tester.pumpAndSettle();
  }

  Future<void> typeBarcode(WidgetTester tester, String code) async {
    await openMoreDetails(tester);
    final field = fieldFor('Barcode');
    await tester.ensureVisible(field);
    await tester.enterText(field, code);
    // Past the lookup debounce.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  Finder notes() => find.text(CatalogueFilledNote.text);

  Uint8List? pendingPhoto(WidgetTester tester) {
    final photo = find.byWidgetPredicate(
      (w) => w is Image && w.image is MemoryImage,
    );
    if (photo.evaluate().isEmpty) return null;
    return (tester.widget<Image>(photo).image as MemoryImage).bytes;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  const fullSuggestion = BarcodeSuggestion(
    name: 'Peak Milk 400g',
    unit: 'Tin',
    photoBytes: null,
  );
  BarcodeSuggestion withPhoto(BarcodeSuggestion s) =>
      BarcodeSuggestion(name: s.name, unit: s.unit, photoBytes: _bigPhoto);

  group('supermarket (no Tin among its starter units)', () {
    setUp(seed);

    testWidgets('a POS-scan prefill fills name, unit and photo, each with the '
        'note; a unit missing from the starter list is added and selected', (
      tester,
    ) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester, prefilledBarcode: _gtin);

      expect(catalogue.calls, [_gtin]);
      expect(catalogue.photoAsked, [true]);
      expect(textOf(tester, 'Product Name'), 'Peak Milk 400g');
      // 'Tin' is not a supermarket starter unit: it is added and selected.
      expect(unitDropdown(tester).currentValue, 'Tin');
      expect(unitOptions(tester), contains('Tin'));

      await openMoreDetails(tester);
      final photo = pendingPhoto(tester);
      expect(photo, isNotNull);
      // Processed exactly as a picked photo: resized to the 800 px cap.
      // JPEG, like a picked photo (#340).
      expect(photo!.sublist(0, 2), [0xFF, 0xD8]);
      final decoded = img.decodeJpg(photo)!;
      expect(decoded.width, 800);
      expect(decoded.height, 400);

      // One note each under name, unit and photo.
      expect(notes(), findsNWidgets(3));

      await unmount(tester);
    });

    testWidgets('typing a factory code into the barcode box fills them', (
      tester,
    ) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester);
      expect(catalogue.calls, isEmpty);

      await typeBarcode(tester, _gtin);

      expect(catalogue.calls, [_gtin]);
      expect(textOf(tester, 'Product Name'), 'Peak Milk 400g');
      expect(unitDropdown(tester).currentValue, 'Tin');
      expect(pendingPhoto(tester), isNotNull);
      expect(notes(), findsNWidgets(3));

      await unmount(tester);
    });

    testWidgets('a photo is only fetched while none is held', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester, prefilledBarcode: _gtin);
      await openMoreDetails(tester);
      expect(pendingPhoto(tester), isNotNull);

      // A photo is now held: the next lookup must not download one.
      await typeBarcode(tester, _otherGtin);
      expect(catalogue.calls, [_gtin, _otherGtin]);
      expect(catalogue.photoAsked, [true, false]);

      await unmount(tester);
    });

    testWidgets('Receive Stock (no photo box) never fetches the photo', (
      tester,
    ) async {
      catalogue.answer = fullSuggestion;
      await pumpScreen(tester, prefilledBarcode: _gtin, receiveMode: true);

      expect(catalogue.calls, [_gtin]);
      expect(catalogue.photoAsked, [false]);
      expect(textOf(tester, 'Product Name'), 'Peak Milk 400g');

      await unmount(tester);
    });

    testWidgets('a typed name is never overwritten: only the empty unit and '
        'photo fill', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester);

      await tester.enterText(fieldFor('Product Name'), 'My own name');
      await tester.pumpAndSettle();
      await typeBarcode(tester, _gtin);

      expect(textOf(tester, 'Product Name'), 'My own name');
      expect(unitDropdown(tester).currentValue, 'Tin');
      expect(pendingPhoto(tester), isNotNull);
      // Notes under unit and photo only.
      expect(notes(), findsNWidgets(2));

      await unmount(tester);
    });

    testWidgets('a late answer after the person typed a name fills only the '
        'empty boxes', (tester) async {
      catalogue.pending = Completer<BarcodeSuggestion?>();
      await pumpScreen(tester, prefilledBarcode: _gtin);
      expect(catalogue.calls, [_gtin]);

      await tester.enterText(fieldFor('Product Name'), 'Typed while waiting');
      await tester.pumpAndSettle();

      catalogue.pending!.complete(withPhoto(fullSuggestion));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'Product Name'), 'Typed while waiting');
      expect(unitDropdown(tester).currentValue, 'Tin');
      await openMoreDetails(tester);
      expect(pendingPhoto(tester), isNotNull);
      expect(notes(), findsNWidgets(2));

      await unmount(tester);
    });

    testWidgets('an answer for a code no longer in the box is dropped', (
      tester,
    ) async {
      catalogue.pending = Completer<BarcodeSuggestion?>();
      await pumpScreen(tester, prefilledBarcode: _gtin);

      await openMoreDetails(tester);
      await tester.enterText(fieldFor('Barcode'), 'SHOP-CODE-9');
      await tester.pumpAndSettle();

      catalogue.pending!.complete(withPhoto(fullSuggestion));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'Product Name'), isEmpty);
      expect(unitDropdown(tester).currentValue, isNull);
      expect(pendingPhoto(tester), isNull);
      expect(notes(), findsNothing);

      await unmount(tester);
    });

    testWidgets('an answer for an earlier code is dropped when the box now holds '
        'another factory code', (tester) async {
      catalogue.pending = Completer<BarcodeSuggestion?>();
      await pumpScreen(tester, prefilledBarcode: _gtin);

      final first = catalogue.pending!;
      catalogue.pending = null;
      catalogue.answer = null;
      await typeBarcode(tester, _otherGtin);
      expect(catalogue.calls, [_gtin, _otherGtin]);

      first.complete(withPhoto(fullSuggestion));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'Product Name'), isEmpty);
      expect(notes(), findsNothing);

      await unmount(tester);
    });

    testWidgets('failure or timeout (null) leaves the boxes empty with no '
        'message', (tester) async {
      catalogue.answer = null;
      await pumpScreen(tester, prefilledBarcode: _gtin);

      expect(catalogue.calls, [_gtin]);
      expect(textOf(tester, 'Product Name'), isEmpty);
      expect(unitDropdown(tester).currentValue, isNull);
      await openMoreDetails(tester);
      expect(pendingPhoto(tester), isNull);
      expect(notes(), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      await unmount(tester);
    });

    testWidgets('a non-GTIN code never calls the service', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester, prefilledBarcode: 'SCAN-1');
      // Digits, right length, wrong check digit; and a shop's own 2-prefix code.
      await typeBarcode(tester, '6150001234562');
      await typeBarcode(tester, '2000000000008');

      expect(catalogue.calls, isEmpty);
      expect(textOf(tester, 'Product Name'), isEmpty);

      await unmount(tester);
    });

    testWidgets('restock mode (an existing product picked) never looks up', (
      tester,
    ) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester);

      await tester.enterText(fieldFor('Product Name'), 'Cok');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Coke 50cl'));
      await tester.pumpAndSettle();
      expect(find.text('Add Stock'), findsWidgets);

      final field = fieldFor('Barcode');
      await tester.ensureVisible(field);
      await tester.enterText(field, _gtin);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(catalogue.calls, isEmpty);
      expect(notes(), findsNothing);

      await unmount(tester);
    });

    testWidgets('edit mode (Update Product) never looks up', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      final product = await (db.select(
        db.products,
      )..where((t) => t.id.equals('prod-coke'))).getSingle();
      await pumpWidgetUnder(
        tester,
        Scaffold(
          body: UpdateProductSheet(product: product, totalStock: 0),
        ),
      );

      final field = fieldFor('Barcode');
      await tester.ensureVisible(field);
      await tester.enterText(field, _gtin);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(catalogue.calls, isEmpty);
      expect(notes(), findsNothing);

      await unmount(tester);
    });

    testWidgets('each note hides once that field is edited', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester, prefilledBarcode: _gtin);
      await openMoreDetails(tester);
      expect(notes(), findsNWidgets(3));

      // Name edited.
      await tester.ensureVisible(fieldFor('Product Name'));
      await tester.enterText(fieldFor('Product Name'), 'Peak Milk 400g tin');
      await tester.pumpAndSettle();
      expect(notes(), findsNWidgets(2));

      // Unit changed by hand.
      unitDropdown(tester).onChanged('Pack');
      await tester.pumpAndSettle();
      expect(unitDropdown(tester).currentValue, 'Pack');
      expect(notes(), findsNWidgets(1));

      // Photo removed (the photo box's remove action).
      tester
          .widget<ProductPhotoField>(find.byType(ProductPhotoField))
          .onRemove!();
      await tester.pumpAndSettle();
      expect(pendingPhoto(tester), isNull);
      expect(notes(), findsNothing);

      await unmount(tester);
    });

    testWidgets('saving with a suggested photo stores it as the shop\'s own '
        'product photo', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester, prefilledBarcode: _gtin);

      await tester.enterText(fieldFor('Selling Price'), '1500');
      await tester.enterText(fieldFor('Quantity'), '3');
      await tester.pumpAndSettle();
      final save = find.widgetWithText(AppButton, 'Add Product');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = await db.catalogDao.findProductByBarcode(_gtin);
      expect(saved, isNotNull);
      expect(saved!.name, 'Peak Milk 400g');
      expect(saved.unit, 'Tin');
      expect(images.saved, hasLength(1));
      expect(images.saved.single.businessId, businessId);
      expect(images.saved.single.productId, saved.id);
      expect(img.decodeJpg(images.saved.single.bytes)!.width, 800);
      expect(
        saved.imageUrl,
        'https://example.test/$businessId/${saved.id}.jpg',
      );

      await unmount(tester);
    });

    testWidgets('saving never waits on the lookup', (tester) async {
      catalogue.pending = Completer<BarcodeSuggestion?>();
      await pumpScreen(tester, prefilledBarcode: _gtin);

      await tester.enterText(fieldFor('Product Name'), 'Saved early');
      await tester.enterText(fieldFor('Selling Price'), '900');
      await tester.enterText(fieldFor('Quantity'), '1');
      await tester.pumpAndSettle();
      final save = find.widgetWithText(AppButton, 'Add Product');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = await db.catalogDao.findProductByBarcode(_gtin);
      expect(saved?.name, 'Saved early');
      expect(images.saved, isEmpty);

      // The lookup still answers later; the screen is gone, nothing breaks.
      catalogue.pending!.complete(withPhoto(fullSuggestion));
      await tester.pumpAndSettle();

      await unmount(tester);
    });
  });

  group('bar (a crate business)', () {
    setUp(() => seed(type: 'bar'));

    testWidgets('a suggested Bottle turns empties tracking on, as picking it by '
        'hand does (crate business)', (tester) async {
      catalogue.answer = const BarcodeSuggestion(name: 'Star 60cl', unit: 'bottle');
      await pumpScreen(tester, prefilledBarcode: _gtin);

      // Matched to the dropdown's own spelling, not added twice.
      expect(unitDropdown(tester).currentValue, 'Bottle');
      expect(
        unitOptions(tester).where((u) => u?.toLowerCase() == 'bottle'),
        hasLength(1),
      );
      await openMoreDetails(tester);
      final track = find.widgetWithText(
        CheckboxListTile,
        'Track empty crate returns',
      );
      await tester.ensureVisible(track);
      expect(tester.widget<CheckboxListTile>(track).value, isTrue);

      await unmount(tester);
    });
  });
}
