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
import 'package:flutter/services.dart';
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
import 'package:reebaplus_pos/shared/scanner/barcode_scan_page.dart';
import 'package:reebaplus_pos/shared/scanner/scanner_providers.dart';
import '../helpers/fake_barcode_scanner.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_filled_note.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_form_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
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

  /// True answers every lookup as "no internet" (#465).
  bool offline = false;
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
  }) async {
    if (offline) return const CatalogueUnreachable();
    final s = await lookup(code, includePhoto: includePhoto);
    return s == null ? const CatalogueNothingShared() : CatalogueFound(s);
  }

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
    Widget home, {
    FakeBarcodeScanner? scanner,
  }) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        barcodeCatalogueServiceProvider.overrideWithValue(catalogue),
        if (scanner != null) barcodeScannerProvider.overrideWithValue(scanner),
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
    container.read(authProvider).value = await db.storesDao.getUserById(userId);
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
    FakeBarcodeScanner? scanner,
    ProductData? editProduct,
  }) => pumpWidgetUnder(
    tester,
    AddProductScreen(
      prefilledBarcode: prefilledBarcode,
      receiveMode: receiveMode,
      editProduct: editProduct,
    ),
    scanner: scanner,
  );

  Finder fieldFor(String labelPart) => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is AppInput && (w.labelText?.contains(labelPart) ?? false),
    ),
    matching: find.byType(TextFormField),
  );

  Finder quantityField() => find.descendant(
    of: find.byKey(AddProductKeys.quantity),
    matching: find.byType(TextFormField),
  );

  String textOf(WidgetTester tester, String labelPart) =>
      tester.widget<TextFormField>(fieldFor(labelPart)).controller!.text;

  // Add Product's unit chips (#487), by their saved values.
  Iterable<ProductUnitChip> chips(WidgetTester tester) =>
      tester.widgetList<ProductUnitChip>(find.byType(ProductUnitChip));

  String chipUnit(ProductUnitChip chip) => (chip.key! as ValueKey<String>).value
      .replaceFirst('add-product-unit-', '');

  List<String> chipUnits(WidgetTester tester) =>
      chips(tester).map(chipUnit).toList();

  String? selectedUnit(WidgetTester tester) =>
      chips(tester).where((c) => c.selected).map(chipUnit).firstOrNull;

  String chipLabel(WidgetTester tester, String unit) => tester
      .widget<ProductUnitChip>(find.byKey(AddProductKeys.unitChip(unit)))
      .label;

  Future<void> typeBarcode(WidgetTester tester, String code) async {
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
      expect(selectedUnit(tester), 'Tin');
      expect(chipUnits(tester), contains('Tin'));

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
      expect(selectedUnit(tester), 'Tin');
      expect(pendingPhoto(tester), isNotNull);
      expect(notes(), findsNWidgets(3));

      await unmount(tester);
    });

    testWidgets('a suggested photo shows in the photo box beside the name', (
      tester,
    ) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester, prefilledBarcode: _gtin);

      // No fold to open (#487): the photo is already on screen.
      expect(
        tester
            .widget<ProductPhotoBox>(find.byType(ProductPhotoBox))
            .pendingBytes,
        isNotNull,
      );
      expect(pendingPhoto(tester), isNotNull);

      await unmount(tester);
    });

    testWidgets('a photo is only fetched while none is held', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester, prefilledBarcode: _gtin);
      expect(pendingPhoto(tester), isNotNull);

      // A photo is now held: the next lookup must not download one.
      await typeBarcode(tester, _otherGtin);
      expect(catalogue.calls, [_gtin, _otherGtin]);
      expect(catalogue.photoAsked, [true, false]);

      await unmount(tester);
    });

    testWidgets('Receive Stock\'s new product is the same form: it fills the '
        'boxes and fetches the photo too (#487)', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester, prefilledBarcode: _gtin, receiveMode: true);

      expect(catalogue.calls, [_gtin]);
      expect(catalogue.photoAsked, [true]);
      expect(textOf(tester, 'Product Name'), 'Peak Milk 400g');
      expect(pendingPhoto(tester), isNotNull);

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
      expect(selectedUnit(tester), 'Tin');
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
      expect(selectedUnit(tester), 'Tin');
      expect(pendingPhoto(tester), isNotNull);
      expect(notes(), findsNWidgets(2));

      await unmount(tester);
    });

    testWidgets('an answer for a code no longer in the box is dropped', (
      tester,
    ) async {
      catalogue.pending = Completer<BarcodeSuggestion?>();
      await pumpScreen(tester, prefilledBarcode: _gtin);

      await tester.enterText(fieldFor('Barcode'), 'SHOP-CODE-9');
      await tester.pumpAndSettle();

      catalogue.pending!.complete(withPhoto(fullSuggestion));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'Product Name'), isEmpty);
      expect(selectedUnit(tester), isNull);
      expect(pendingPhoto(tester), isNull);
      expect(notes(), findsNothing);

      await unmount(tester);
    });

    testWidgets(
      'an answer for an earlier code is dropped when the box now holds '
      'another factory code',
      (tester) async {
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
      },
    );

    testWidgets('failure or timeout (null) leaves the boxes empty with no '
        'message', (tester) async {
      catalogue.answer = null;
      await pumpScreen(tester, prefilledBarcode: _gtin);

      expect(catalogue.calls, [_gtin]);
      expect(textOf(tester, 'Product Name'), isEmpty);
      expect(selectedUnit(tester), isNull);
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

    testWidgets('edit mode never looks up', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      final product = await (db.select(
        db.products,
      )..where((t) => t.id.equals('prod-coke'))).getSingle();
      await pumpWidgetUnder(tester, AddProductScreen(editProduct: product));

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
      expect(notes(), findsNWidgets(3));

      // Name edited.
      await tester.ensureVisible(fieldFor('Product Name'));
      await tester.enterText(fieldFor('Product Name'), 'Peak Milk 400g tin');
      await tester.pumpAndSettle();
      expect(notes(), findsNWidgets(2));

      // Unit changed by hand.
      await tester.ensureVisible(find.byKey(AddProductKeys.unitChip('Pack')));
      await tester.tap(find.byKey(AddProductKeys.unitChip('Pack')));
      await tester.pumpAndSettle();
      expect(selectedUnit(tester), 'Pack');
      expect(notes(), findsNWidgets(1));

      // Photo removed (the photo box's remove action).
      tester.widget<ProductPhotoBox>(find.byType(ProductPhotoBox)).onRemove!();
      await tester.pumpAndSettle();
      expect(pendingPhoto(tester), isNull);
      expect(notes(), findsNothing);

      await unmount(tester);
    });

    testWidgets('saving with a suggested photo stores it as the shop\'s own '
        'product photo', (tester) async {
      catalogue.answer = withPhoto(fullSuggestion);
      await pumpScreen(tester, prefilledBarcode: _gtin);

      await tester.enterText(fieldFor('Retail Price'), '1500');
      await tester.enterText(quantityField(), '3');
      await tester.pumpAndSettle();
      final save = find.widgetWithText(AppButton, 'Save Product');
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
      await tester.enterText(fieldFor('Retail Price'), '900');
      await tester.enterText(quantityField(), '1');
      await tester.pumpAndSettle();
      final save = find.widgetWithText(AppButton, 'Save Product');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = await db.catalogDao.findProductByBarcode(_gtin);
      expect(saved?.name, 'Saved Early'); // name-cased on save (#507)
      expect(images.saved, isEmpty);

      // The lookup still answers later; the screen is gone, nothing breaks.
      catalogue.pending!.complete(withPhoto(fullSuggestion));
      await tester.pumpAndSettle();

      await unmount(tester);
    });
  });

  group('bar (a crate business)', () {
    setUp(() => seed(type: 'bar'));

    testWidgets(
      'a suggested Bottle turns empties tracking on, as picking it by '
      'hand does (crate business)',
      (tester) async {
        catalogue.answer = const BarcodeSuggestion(
          name: 'Star 60cl',
          unit: 'bottle',
        );
        await pumpScreen(tester, prefilledBarcode: _gtin);

        // Matched to the chips' own spelling, not added twice.
        expect(selectedUnit(tester), 'Bottle');
        expect(
          chipUnits(tester).where((u) => u.toLowerCase() == 'bottle'),
          hasLength(1),
        );
        final track = find.byKey(AddProductKeys.trackEmpties);
        await tester.ensureVisible(track);
        expect(tester.widget<Switch>(track).value, isTrue);

        await unmount(tester);
      },
    );

    // #487: "Bottle" reads "Bottle Crate" (the saved value stays Bottle), and
    // plain "Crate" is not offered to a new product.
    Future<void> addCrateProduct() => db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: const Value('prod-crate'),
            businessId: businessId,
            name: 'Old Crate Lager',
            unit: const Value('Crate'),
          ),
        );

    testWidgets('a new product is not offered plain Crate, even when another '
        'product uses it; Bottle reads "Bottle Crate"', (tester) async {
      await addCrateProduct();
      await pumpScreen(tester);

      expect(chipUnits(tester), isNot(contains('Crate')));
      expect(chipUnits(tester), contains('Bottle'));
      expect(chipLabel(tester, 'Bottle'), 'Bottle Crate');
      expect(chipLabel(tester, 'Can'), 'Can');

      await unmount(tester);
    });

    testWidgets('a suggested plain Crate is not filled in', (tester) async {
      catalogue.answer = const BarcodeSuggestion(
        name: 'Crate Lager',
        unit: 'Crate',
      );
      await pumpScreen(tester, prefilledBarcode: _gtin);

      expect(textOf(tester, 'Name'), 'Crate Lager');
      expect(selectedUnit(tester), isNull);
      expect(chipUnits(tester), isNot(contains('Crate')));

      await unmount(tester);
    });

    testWidgets('Edit Product on a product saved as Crate still shows and '
        'offers Crate', (tester) async {
      await addCrateProduct();
      final product = await (db.select(
        db.products,
      )..where((t) => t.id.equals('prod-crate'))).getSingle();
      await pumpWidgetUnder(tester, AddProductScreen(editProduct: product));

      expect(selectedUnit(tester), 'Crate');
      expect(chipUnits(tester), contains('Crate'));

      await unmount(tester);
    });
  });

  // #465 / #487 PR 6: the scan button and the own-products check.
  group('scan a barcode on Add Product', () {
    setUp(seed);

    Future<void> addOwn(String id, String name, String barcode) => db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            barcode: Value(barcode),
          ),
        );

    Future<void> scan(
      WidgetTester tester,
      FakeBarcodeScanner scanner,
      String code,
    ) async {
      final button = find.byTooltip('Scan barcode');
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      scanner.camera!.read(code);
      await tester.pumpAndSettle();
    }

    testWidgets('own product: "You already have", Open it, and the shared '
        'list is not asked; the camera closes after the first read', (
      tester,
    ) async {
      await addOwn('p-own', 'Own Cola', '9988');
      final scanner = FakeBarcodeScanner();
      await pumpScreen(tester, scanner: scanner);
      await scan(tester, scanner, '9988');

      expect(scanner.sessionCount, 1);
      expect(find.byType(BarcodeScanPage), findsNothing);
      expect(scanner.camera!.isDisposed, isTrue);
      expect(textOf(tester, 'Barcode'), '9988');
      expect(find.text('You already have Own Cola'), findsOneWidget);
      expect(find.text('Create a new product anyway'), findsOneWidget);
      expect(catalogue.calls, isEmpty);

      await unmount(tester);
    });

    testWidgets('Create a new product anyway dismisses the card', (
      tester,
    ) async {
      await addOwn('p-own', 'Own Cola', '9988');
      final scanner = FakeBarcodeScanner();
      await pumpScreen(tester, scanner: scanner);
      await scan(tester, scanner, '9988');
      await tester.tap(find.text('Create a new product anyway'));
      await tester.pumpAndSettle();
      expect(find.text('You already have Own Cola'), findsNothing);
      await unmount(tester);
    });

    testWidgets('several matches are listed', (tester) async {
      await addOwn('p-a', 'Cola One', '7766');
      await addOwn('p-b', 'Cola Two', '7766');
      final scanner = FakeBarcodeScanner();
      await pumpScreen(tester, scanner: scanner);
      await scan(tester, scanner, '7766');
      expect(
        find.text('You already have 2 products with this barcode'),
        findsOneWidget,
      );
      expect(find.text('Cola One'), findsOneWidget);
      expect(find.text('Cola Two'), findsOneWidget);
      expect(find.text('Open it'), findsNWidgets(2));
      await unmount(tester);
    });

    testWidgets('a shared-list hit fills only the empty boxes', (tester) async {
      catalogue.answer = fullSuggestion;
      final scanner = FakeBarcodeScanner();
      await pumpScreen(tester, scanner: scanner);
      await tester.enterText(fieldFor('Product Name'), 'Mine');
      await tester.pump();
      await scan(tester, scanner, _gtin);
      expect(catalogue.calls, [_gtin]);
      expect(textOf(tester, 'Product Name'), 'Mine');
      expect(selectedUnit(tester), 'Tin');
      expect(notes(), findsOneWidget); // the unit only
      await unmount(tester);
    });

    testWidgets('a shop-made code never calls the shared list', (tester) async {
      final scanner = FakeBarcodeScanner();
      await pumpScreen(tester, scanner: scanner);
      await scan(tester, scanner, '12345');
      expect(catalogue.calls, isEmpty);
      expect(find.text('New barcode — fill in the details'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('offline: the own check still runs, the shared list is '
        'skipped with a note, and saving is not blocked', (tester) async {
      catalogue.offline = true;
      await addOwn('p-own', 'Own Cola', '9988');
      final scanner = FakeBarcodeScanner();
      await pumpScreen(tester, scanner: scanner);
      await scan(tester, scanner, '9988');
      expect(find.text('You already have Own Cola'), findsOneWidget);
      expect(find.textContaining('no internet'), findsNothing);

      await tester.enterText(fieldFor('Barcode'), _gtin);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(
        find.text("Couldn't check the shared list — no internet"),
        findsOneWidget,
      );
      expect(
        tester.widget<AppButton>(find.byType(AppButton).last).onPressed,
        isNotNull,
      );
      await unmount(tester);
    });

    testWidgets('edit mode: the scan only drops the code into the box', (
      tester,
    ) async {
      await addOwn('p-own', 'Own Cola', '9988');
      await addOwn('p-other', 'Other', '5544');
      final product = (await db.catalogDao.findById('p-own'))!;
      final scanner = FakeBarcodeScanner();
      await pumpScreen(tester, scanner: scanner, editProduct: product);
      await scan(tester, scanner, _gtin);
      expect(textOf(tester, 'Barcode'), _gtin);
      expect(find.byType(ProductBarcodeMatchesCard), findsNothing);
      expect(catalogue.calls, isEmpty);
      await unmount(tester);
    });

    testWidgets('keyboard up: the barcode box stays reachable', (tester) async {
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await pumpScreen(tester);
      await tester.ensureVisible(fieldFor('Barcode'));
      await tester.enterText(fieldFor('Barcode'), '555');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  });
}
