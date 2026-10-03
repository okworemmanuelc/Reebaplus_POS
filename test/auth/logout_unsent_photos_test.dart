// logout_unsent_photos_test.dart
//
// #343. A product photo saved offline waits in the pending-uploads list, not
// the sync outbox, so the logout wipe gate must count it too:
//   * offline → refused with "connect and sync first", naming the photo;
//   * online, the upload tried and still failed → the Resolve flow (never a
//     trap), carrying the photo count;
//   * online, the upload worked → the logout goes through;
//   * a photo whose product was deleted, or whose copy is gone, can never
//     upload and never blocks.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/local_photo_files.dart';
import 'package:reebaplus_pos/core/services/pending_photo_uploads.dart';
import 'package:reebaplus_pos/core/services/product_image_service.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

class _FakeSecureStorageService extends SecureStorageService {
  String? userId;

  @override
  Future<String?> getDeviceUserId() async => userId;

  @override
  Future<void> saveDeviceUserId(String userId) async {
    this.userId = userId;
  }

  @override
  Future<void> clearDeviceUserId() async {
    userId = null;
  }

  @override
  Future<void> clearAll() async {
    userId = null;
  }
}

/// Real counting (prefs + temp photo folder + catalogue); the upload is faked
/// so no network is touched. [uploadSucceeds] decides whether a try clears
/// the list.
class _FakePhotoUploads extends PendingPhotoUploads {
  _FakePhotoUploads({
    required super.images,
    required super.catalog,
    required super.documents,
  });

  bool uploadSucceeds = false;
  int uploadCalls = 0;

  @override
  Future<void> upload(String businessId) async {
    uploadCalls++;
    if (!uploadSucceeds) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(LocalPhotoFiles.pendingProductUploadsKey, []);
  }
}

void main() {
  late AppDatabase db;
  late SupabaseSyncService sync;
  late _FakePhotoUploads photos;
  late AuthService auth;
  late Directory docs;
  late String biz;
  late String productId;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _connectivityChannel,
          (call) async => call.method == 'check' ? <String>['wifi'] : null,
        );
    try {
      await Supabase.initialize(
        url: 'https://placeholder.supabase.co',
        anonKey: 'placeholder',
      );
    } catch (_) {}
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    docs = Directory.systemTemp.createTempSync('logout_photos_test');
    final client = Supabase.instance.client;
    sync = SupabaseSyncService(db, SupabaseCloudTransport(client));
    photos = _FakePhotoUploads(
      images: ProductImageService(client),
      catalog: db.catalogDao,
      documents: docs,
    );
    auth = AuthService(
      db,
      NavigationService(),
      _FakeSecureStorageService(),
      sync,
      client,
      pendingPhotos: photos,
    );

    biz = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(BusinessesCompanion.insert(id: Value(biz), name: 'Shop'));
    final roleId = UuidV7.generate();
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(roleId), businessId: biz, name: 'CEO', slug: 'ceo'));
    final userId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(userId),
          businessId: biz,
          name: 'Owner',
          pin: '__HASHED__',
        ));
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: biz,
          userId: userId,
          roleId: roleId,
        ));
    productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(productId),
          businessId: biz,
          name: 'Star 60cl',
        ));

    // One photo saved offline for that product.
    Directory('${docs.path}/product_images').createSync();
    File('${docs.path}/product_images/$productId.png')
        .writeAsBytesSync([1, 2, 3]);
    SharedPreferences.setMockInitialValues({
      LocalPhotoFiles.pendingProductUploadsKey: ['$biz|$productId'],
    });

    auth.value = await (db.select(db.users)
          ..where((u) => u.id.equals(userId)))
        .getSingle();
  });

  tearDown(() async {
    await db.close();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  Future<bool> deviceWiped() async =>
      (await db.select(db.businesses).get()).isEmpty;

  test('offline: logout is refused and the message names the photo', () async {
    sync.isOnline.value = false;

    await expectLater(
      auth.logOutCurrentUser(),
      throwsA(isA<LogoutWipeException>().having(
        (e) => e.message,
        'message',
        'You have 1 product photo not uploaded yet. Connect to the internet '
            'and let it sync before signing out.',
      )),
    );
    expect(await deviceWiped(), isFalse);
    expect(auth.value, isNotNull);
    expect(photos.uploadCalls, 0, reason: 'no upload attempt while offline');
  });

  test('online and the upload works: the logout goes through', () async {
    photos.uploadSucceeds = true;

    await auth.logOutCurrentUser();

    expect(photos.uploadCalls, 1);
    expect(await deviceWiped(), isTrue);
    expect(auth.value, isNull);
  });

  test('online and the upload still fails: routed to the Resolve flow, never '
      'trapped', () async {
    await expectLater(
      auth.logOutCurrentUser(),
      throwsA(isA<LogoutBlockedByUnsyncedDataException>()
          .having((e) => e.photoCount, 'photoCount', 1)
          .having((e) => e.pendingCount, 'pendingCount', 0)
          .having((e) => e.orphanCount, 'orphanCount', 0)),
    );
    expect(photos.uploadCalls, 1);
    expect(await deviceWiped(), isFalse);
  });

  test('a photo whose product was deleted never blocks the logout', () async {
    sync.isOnline.value = false;
    await (db.update(db.products)..where((p) => p.id.equals(productId)))
        .write(const ProductsCompanion(isDeleted: Value(true)));

    await auth.logOutCurrentUser();

    expect(await deviceWiped(), isTrue);
  });

  test('a photo whose copy is gone never blocks the logout', () async {
    sync.isOnline.value = false;
    File('${docs.path}/product_images/$productId.png').deleteSync();

    await auth.logOutCurrentUser();

    expect(await deviceWiped(), isTrue);
  });

  test('unsent changes and photos are named together', () {
    expect(
      AuthService.unsyncedBeforeWipeMessage(changes: 2, photos: 3),
      'You have 2 changes not yet synced and 3 product photos not uploaded '
      'yet. Connect to the internet and let it sync before signing out.',
    );
    expect(
      AuthService.unsyncedBeforeWipeMessage(changes: 1, photos: 0),
      'You have 1 change not yet synced. Connect to the internet and let it '
      'sync before signing out.',
    );
  });
}
