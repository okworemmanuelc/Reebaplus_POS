// #659: tapping the product photo to change it locks on the first tap, shows
// a spinner over the photo while the picker and the upload run, and opens the
// picker once.
//
// #763: the tap first asks "Take photo" or "Choose from gallery", the choice
// reaches the picker, and Add Product's photo box spins while the photo is
// being shrunk.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart' show ImageSource;

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/photo_source_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_form_parts.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/product_detail_seed.dart';
import '../helpers/screen_harness.dart';

class _SlowPicker extends ProductImageService {
  _SlowPicker(super.client);

  int picks = 0;
  ImageSource? lastSource;
  final gate = Completer<Result<Uint8List, AppError>>();

  @override
  Future<Result<Uint8List, AppError>> pickAndProcess({
    ImageSource source = ImageSource.gallery,
  }) {
    picks++;
    lastSource = source;
    return gate.future;
  }
}

/// Lets a modal sheet slide in or out.
Future<void> _settleSheet(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;
  late Directory docs;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    docs = Directory.systemTemp.createTempSync('product_photo_lock');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => docs.path);
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    docs.deleteSync(recursive: true);
  });

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    sample = await seedInventorySample(env);
  });
  tearDown(() => env.dispose());

  Future<_SlowPicker> pumpDetails(WidgetTester tester) async {
    final client = await initTestSupabase();
    final picker = _SlowPicker(client);
    await seedDetailSample(env, sample);
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      screen: ProductDetailScreen(
        item: detailItemFor(env, sample),
        onUpdateStock: () {},
        selectedStoreId: env.storeId,
      ),
      settle: false,
      grantedKeys: const {
        ...kInventorySampleGrants,
        'products.manage_listing',
      },
      overrides: [productImageServiceProvider.overrideWithValue(picker)],
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    return picker;
  }

  testWidgets('two quick taps ask once, open the picker once, photo spins',
      (tester) async {
    final picker = await pumpDetails(tester);

    final photo = find.bySemanticsLabel('Change photo');
    expect(find.byKey(const Key('product-photo-busy')), findsNothing);
    await tester.tap(photo);
    await tester.tap(photo);
    await _settleSheet(tester);
    expect(find.byKey(PhotoSourceSheetKeys.sheet), findsOneWidget);
    expect(picker.picks, 0);

    await tester.tap(find.byKey(PhotoSourceSheetKeys.gallery));
    await tester.pump();
    expect(picker.picks, 1);
    expect(picker.lastSource, ImageSource.gallery);
    expect(find.byKey(const Key('product-photo-busy')), findsOneWidget);

    // The user cancels the picker: the spinner goes away and it can reopen.
    picker.gate.complete(Result.err(AppError.cancelled()));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('product-photo-busy')), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('"Take photo" opens the camera (#763)', (tester) async {
    final picker = await pumpDetails(tester);

    await tester.tap(find.bySemanticsLabel('Change photo'));
    await _settleSheet(tester);
    await tester.tap(find.byKey(PhotoSourceSheetKeys.camera));
    await tester.pump();
    expect(picker.picks, 1);
    expect(picker.lastSource, ImageSource.camera);

    picker.gate.complete(Result.err(AppError.cancelled()));
    await tester.pump();
    await disposeScreen(tester);
  });

  testWidgets('dismissing the question opens nothing and frees the photo',
      (tester) async {
    final picker = await pumpDetails(tester);

    await tester.tap(find.bySemanticsLabel('Change photo'));
    await _settleSheet(tester);
    await tester.tapAt(const Offset(195, 60)); // the scrim above the sheet
    await _settleSheet(tester);
    expect(find.byKey(PhotoSourceSheetKeys.sheet), findsNothing);
    expect(picker.picks, 0);
    expect(find.byKey(const Key('product-photo-busy')), findsNothing);

    // Not left locked: the next tap asks again.
    await tester.tap(find.bySemanticsLabel('Change photo'));
    await _settleSheet(tester);
    expect(find.byKey(PhotoSourceSheetKeys.sheet), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('Add Product: the photo box spins while the photo is shrunk',
      (tester) async {
    final client = await initTestSupabase();
    final picker = _SlowPicker(client);
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      screen: const AddProductScreen(),
      grantedKeys: const {
        ...kInventorySampleGrants,
        'products.edit_buying_price',
      },
      overrides: [
        productImageServiceProvider.overrideWithValue(picker),
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
    );

    const busy = Key('product-photo-box-busy');
    final box = find.byType(ProductPhotoBox);
    await tester.ensureVisible(box);
    await tester.tap(box);
    await tester.tap(box);
    await _settleSheet(tester);
    expect(find.byKey(PhotoSourceSheetKeys.sheet), findsOneWidget);
    expect(find.byKey(busy), findsNothing);

    await tester.tap(find.byKey(PhotoSourceSheetKeys.camera));
    await _settleSheet(tester);
    expect(picker.picks, 1);
    expect(picker.lastSource, ImageSource.camera);
    expect(find.byKey(busy), findsOneWidget);

    // A tiny real JPEG stands in for the shrunk photo.
    picker.gate.complete(Result.ok(_tinyJpeg));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(busy), findsNothing);
    expect(tester.widget<ProductPhotoBox>(box).pendingBytes, _tinyJpeg);
    await disposeScreen(tester);
  });
}

/// A small real JPEG.
final _tinyJpeg = Uint8List.fromList(
  img.encodeJpg(img.Image(width: 4, height: 4)),
);
