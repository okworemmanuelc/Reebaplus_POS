// #659: tapping the product photo to change it locks on the first tap, shows
// a spinner over the photo while the picker and the upload run, and opens the
// picker once.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/product_detail_seed.dart';
import '../helpers/screen_harness.dart';

class _SlowPicker extends ProductImageService {
  _SlowPicker(super.client);

  int picks = 0;
  final gate = Completer<Result<Uint8List, AppError>>();

  @override
  Future<Result<Uint8List, AppError>> pickAndProcess({
    ImageSource source = ImageSource.gallery,
  }) {
    picks++;
    return gate.future;
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

  testWidgets('two quick taps open the picker once and the photo spins',
      (tester) async {
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

    final photo = find.bySemanticsLabel('Change photo');
    expect(find.byKey(const Key('product-photo-busy')), findsNothing);
    await tester.tap(photo);
    await tester.tap(photo);
    expect(picker.picks, 1);
    await tester.pump();
    expect(find.byKey(const Key('product-photo-busy')), findsOneWidget);

    // The user cancels the picker: the spinner goes away and it can reopen.
    picker.gate.complete(Result.err(AppError.cancelled()));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('product-photo-busy')), findsNothing);
    await disposeScreen(tester);
  });
}
