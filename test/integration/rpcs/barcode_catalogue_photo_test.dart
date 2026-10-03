@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/factory_barcode.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Tier-2 integration tests for the shared barcode catalogue photo (#331,
/// ADR 0029 §5/§6).
///
/// Hits real dev Supabase end to end: the products trigger → pg_net →
/// `share-barcode-photo` Edge Function → `barcode-catalogue-photos` bucket +
/// `barcode_catalogue_photos` row. Needs migration 0182, the deployed function
/// and both hook secrets; the pipeline is asynchronous, so tests poll.
///
/// Every test uses fresh random GTINs under GS1 prefix 19 (unassigned by GS1,
/// so never a real product's code) and its own throwaway businesses, and
/// cleans up its rows and objects.
final String? _skipReason = (() {
  try {
    TestEnv.load();
    return null;
  } on StateError catch (e) {
    return e.message;
  }
})();

const _sharedBucket = 'barcode-catalogue-photos';
const _sourceBucket = 'product-images';

/// A 1x1 PNG. Bytes appended after IEND keep it valid while making every
/// test photo's hash distinct.
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

final _random = Random.secure();

Uint8List _photo(String tag) =>
    Uint8List.fromList([..._png1x1, ...utf8.encode('$tag-${_random.nextInt(1 << 32)}')]);

String _sha256(Uint8List bytes) => sha256.convert(bytes).toString();

/// A random factory GTIN-13 under prefix 19.
String _randomGtin13() {
  final body = '19${List.generate(10, (_) => _random.nextInt(10)).join()}';
  for (var check = 0; check < 10; check++) {
    if (FactoryBarcode.isFactoryGtin('$body$check')) return '$body$check';
  }
  throw StateError('no check digit for $body');
}

void main() {
  late TestClients clients;
  final createdBusinessIds = <String>[];
  final createdProductIds = <String>[];
  final sourcePaths = <String>[];
  final touchedGtin14s = <String>{};

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
  });

  tearDown(() async {
    if (_skipReason != null) return;
    final admin = clients.adminClient;

    // Every step runs even if an earlier one fails, so a broken run still
    // removes what it created on the shared project.
    Future<void> attempt(String what, Future<void> Function() step) async {
      try {
        await step();
      } on Object catch (e) {
        printOnFailure('cleanup "$what" failed: $e');
      }
    }

    final productIds = createdProductIds.toList();
    final gtins = touchedGtin14s.toList();
    final paths = sourcePaths.toList();
    final businessIds = createdBusinessIds.toList();
    createdProductIds.clear();
    touchedGtin14s.clear();
    sourcePaths.clear();
    createdBusinessIds.clear();

    // Products first, so a late share request finds no candidate.
    if (productIds.isNotEmpty) {
      await attempt('products', () => admin.from('products').delete().inFilter('id', productIds));
    }
    if (gtins.isNotEmpty) {
      await attempt(
        'photo rows',
        () => admin.from('barcode_catalogue_photos').delete().inFilter('gtin14', gtins),
      );
      await attempt(
        'photo blocks',
        () => admin.from('barcode_catalogue_photo_blocks').delete().inFilter('gtin14', gtins),
      );
      await attempt(
        'shared objects',
        () => admin.storage.from(_sharedBucket).remove([for (final g in gtins) '$g.png']),
      );
    }
    if (paths.isNotEmpty) {
      await attempt('source objects', () => admin.storage.from(_sourceBucket).remove(paths));
    }
    for (final bid in businessIds) {
      await attempt('business $bid', () => admin.from('businesses').delete().eq('id', bid));
    }
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  // ── fixtures ──────────────────────────────────────────────────────────────

  String gtin14Of(String code) {
    final g = FactoryBarcode.padToGtin14(code)!;
    touchedGtin14s.add(g);
    return g;
  }

  Future<String> createBusiness(String name) async {
    final bid = UuidV7.generate();
    await clients.adminClient.from('businesses').insert({'id': bid, 'name': name});
    createdBusinessIds.add(bid);
    return bid;
  }

  /// Uploads [bytes] as the business's own product photo and returns its
  /// public URL, exactly as ProductImageService does.
  Future<String> uploadSource(String businessId, String productId, Uint8List bytes) async {
    final path = '$businessId/$productId.png';
    await clients.adminClient.storage.from(_sourceBucket).uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(upsert: true, contentType: 'image/png'),
        );
    sourcePaths.add(path);
    return clients.adminClient.storage.from(_sourceBucket).getPublicUrl(path);
  }

  /// Inserts a product (as a sync push would) with an optional photo.
  Future<String> insertProduct({
    required String businessId,
    String? barcode,
    Uint8List? photo,
    DateTime? createdAt,
  }) async {
    final pid = UuidV7.generate();
    createdProductIds.add(pid);
    await clients.adminClient.from('products').insert({
      'id': pid,
      'business_id': businessId,
      'name': 'Catalogue photo test',
      'barcode': barcode,
      'image_url': photo == null ? null : await uploadSource(businessId, pid, photo),
      if (createdAt != null) 'created_at': createdAt.toUtc().toIso8601String(),
    });
    return pid;
  }

  Future<Map<String, dynamic>?> sharedRow(String gtin14) => clients.adminClient
      .from('barcode_catalogue_photos')
      .select()
      .eq('gtin14', gtin14)
      .maybeSingle();

  /// Polls until the GTIN has a shared photo row (the pipeline is async).
  Future<Map<String, dynamic>> waitForSharedRow(String gtin14) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      final row = await sharedRow(gtin14);
      if (row != null) return row;
      await Future<void>.delayed(const Duration(milliseconds: 750));
    }
    fail('no barcode_catalogue_photos row for $gtin14 within 60 s — is '
        'share-barcode-photo deployed and are both hook secrets set?');
  }

  Future<Uint8List?> sharedObject(String gtin14) async {
    try {
      return await clients.adminClient.storage.from(_sharedBucket).download('$gtin14.png');
    } on StorageException {
      return null;
    }
  }

  String publicUrl(String gtin14) =>
      '${clients.env.url}/storage/v1/object/public/$_sharedBucket/$gtin14.png';

  Future<(int, Uint8List)> httpGet(String url) async {
    final http = HttpClient();
    try {
      final res = await (await http.getUrl(Uri.parse(url))).close();
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      return (res.statusCode, Uint8List.fromList(bytes));
    } finally {
      http.close();
    }
  }

  // ── tests ─────────────────────────────────────────────────────────────────

  group('share-barcode-photo pipeline (Tier 2)', () {
    test(
      'the first photo is copied to <gtin14>.png, barcode_suggestion returns '
      'its public URL, and it survives the source shop deleting its photo and product',
      () async {
        final code = _randomGtin13();
        final g = gtin14Of(code);
        final bizA = await createBusiness('Photo Biz A');
        final photoA = _photo('a');
        final productA = await insertProduct(businessId: bizA, barcode: code, photo: photoA);

        final row = await waitForSharedRow(g);
        expect(row['object_path'], '$g.png');
        expect(row['sha256'], _sha256(photoA));
        expect(await sharedObject(g), photoA);

        final suggestion = await clients.userClient.rpc(
          'barcode_suggestion',
          params: {'p_barcode': code},
        ) as List<dynamic>;
        expect(suggestion, hasLength(1));
        expect((suggestion.single as Map)['photo_url'], publicUrl(g));

        final (status, bytes) = await httpGet(publicUrl(g));
        expect(status, 200);
        expect(bytes, photoA);

        // The source shop removes its photo, then its product.
        await clients.adminClient.storage.from(_sourceBucket).remove(['$bizA/$productA.png']);
        await clients.adminClient
            .from('products')
            .update({'image_url': null, 'is_deleted': true}).eq('id', productA);
        await clients.adminClient.from('products').delete().eq('id', productA);

        expect(await sharedObject(g), photoA);
        expect((await sharedRow(g))!['sha256'], _sha256(photoA));
        final (statusAfter, _) = await httpGet(publicUrl(g));
        expect(statusAfter, 200);
      },
      skip: _skipReason,
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      "a second shop's photo for the same code does not replace the first",
      () async {
        final code = _randomGtin13();
        final g = gtin14Of(code);
        final bizA = await createBusiness('Photo Biz A');
        final bizB = await createBusiness('Photo Biz B');
        final photoA = _photo('a');
        await insertProduct(businessId: bizA, barcode: code, photo: photoA);
        await waitForSharedRow(g);

        // Second shop saves its own photo for the same code, alongside a
        // control product whose share proves the pipeline ran meanwhile.
        final controlCode = _randomGtin13();
        final controlG = gtin14Of(controlCode);
        await insertProduct(businessId: bizB, barcode: code, photo: _photo('b'));
        await insertProduct(businessId: bizB, barcode: controlCode, photo: _photo('c'));
        await waitForSharedRow(controlG);

        expect((await sharedRow(g))!['sha256'], _sha256(photoA));
        expect(await sharedObject(g), photoA);
      },
      skip: _skipReason,
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'setting the barcode on a product that already has a photo shares it',
      () async {
        final code = _randomGtin13();
        final g = gtin14Of(code);
        final biz = await createBusiness('Photo Biz');
        final photo = _photo('late-barcode');
        final pid = await insertProduct(businessId: biz, photo: photo);

        await clients.adminClient.from('products').update({'barcode': code}).eq('id', pid);

        final row = await waitForSharedRow(g);
        expect(row['sha256'], _sha256(photo));
      },
      skip: _skipReason,
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'a product whose code is not a factory GTIN never shares',
      () async {
        final valid = _randomGtin13();
        final lastDigit = int.parse(valid[12]);
        final badCheckDigit = '${valid.substring(0, 12)}${(lastDigit + 1) % 10}';
        // A valid check digit under in-store prefix 2 (restricted circulation).
        final body = '20${List.generate(10, (_) => _random.nextInt(10)).join()}';
        final inStore =
            [for (var d = 0; d < 10; d++) '$body$d'].firstWhere(_checkDigitOk);
        expect(FactoryBarcode.isFactoryGtin(badCheckDigit), isFalse);
        expect(FactoryBarcode.isFactoryGtin(inStore), isFalse);

        final biz = await createBusiness('Photo Biz');
        await insertProduct(businessId: biz, barcode: badCheckDigit, photo: _photo('x'));
        await insertProduct(businessId: biz, barcode: inStore, photo: _photo('y'));
        // Control: a factory code saved after them does share.
        final controlCode = _randomGtin13();
        await insertProduct(businessId: biz, barcode: controlCode, photo: _photo('z'));
        await waitForSharedRow(gtin14Of(controlCode));

        for (final code in [badCheckDigit, inStore]) {
          final g = gtin14Of(code);
          expect(await sharedRow(g), isNull, reason: code);
          expect(await sharedObject(g), isNull, reason: code);
        }
      },
      skip: _skipReason,
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'a blocked hash is never shared; the {gtin14} mode skips it and '
      'promotes the next-oldest photo (removal runbook)',
      () async {
        final admin = clients.adminClient;
        final code = _randomGtin13();
        final g = gtin14Of(code);
        final photos = [for (final t in ['w', 'x', 'y', 'z']) _photo(t)];
        final [blockedFromStart, firstShared, nextOldest, newest] = photos;

        await admin.from('barcode_catalogue_photo_blocks').insert({
          'sha256': _sha256(blockedFromStart),
          'gtin14': g,
        });

        // Oldest first: W (blocked), X, Y, Z.
        for (var i = 0; i < photos.length; i++) {
          await insertProduct(
            businessId: await createBusiness('Photo Biz $i'),
            barcode: code,
            photo: photos[i],
            createdAt: DateTime.utc(2026, 1, 1 + i),
          );
          if (i == 1) {
            // W was blocked, so X becomes the shared photo.
            final row = await waitForSharedRow(g);
            expect(row['sha256'], _sha256(firstShared));
          }
        }
        expect((await sharedRow(g))!['sha256'], _sha256(firstShared));

        // Runbook: block X, delete its row and object, request {gtin14}.
        await admin.from('barcode_catalogue_photo_blocks').insert({
          'sha256': _sha256(firstShared),
          'gtin14': g,
        });
        await admin.from('barcode_catalogue_photos').delete().eq('gtin14', g);
        await admin.storage.from(_sharedBucket).remove(['$g.png']);
        final requestId = await admin.rpc(
          'barcode_catalogue_request_share',
          params: {
            'p_body': {'gtin14': g},
          },
        );
        expect(requestId, isNotNull, reason: 'hook secret missing from Vault');

        final row = await waitForSharedRow(g);
        expect(row['sha256'], _sha256(nextOldest));
        expect(await sharedObject(g), nextOldest);
        expect(row['sha256'], isNot(_sha256(newest)));
      },
      skip: _skipReason,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });

  group('barcode-catalogue-photos is service-role only (Tier 2)', () {
    test(
      'an authenticated client cannot write, overwrite or delete in the '
      'bucket, nor reach the photo tables or helper functions',
      () async {
        final user = clients.userClient;
        final g = gtin14Of(_randomGtin13());
        final original = _photo('original');
        await clients.adminClient.storage.from(_sharedBucket).uploadBinary(
              '$g.png',
              original,
              fileOptions: const FileOptions(contentType: 'image/png'),
            );
        final other = gtin14Of(_randomGtin13());

        await expectLater(
          user.storage.from(_sharedBucket).uploadBinary('$other.png', _photo('new')),
          throwsA(isA<StorageException>()),
        );
        await expectLater(
          user.storage.from(_sharedBucket).uploadBinary(
                '$g.png',
                _photo('overwrite'),
                fileOptions: const FileOptions(upsert: true),
              ),
          throwsA(isA<StorageException>()),
        );
        await expectLater(
          user.storage.from(_sharedBucket).updateBinary('$g.png', _photo('update')),
          throwsA(isA<StorageException>()),
        );
        // Storage answers a delete RLS hides with an empty list, not an error.
        try {
          await user.storage.from(_sharedBucket).remove(['$g.png']);
        } on StorageException {
          // also acceptable
        }
        expect(await sharedObject(g), original);
        expect(await sharedObject(other), isNull);

        final anon = SupabaseClient(clients.env.url, clients.env.anonKey);
        try {
          await expectLater(
            anon.storage.from(_sharedBucket).uploadBinary('$other.png', _photo('anon')),
            throwsA(isA<StorageException>()),
          );
        } finally {
          await anon.dispose();
        }

        for (final table in ['barcode_catalogue_photos', 'barcode_catalogue_photo_blocks']) {
          await expectLater(
            user.from(table).select(),
            throwsA(isA<PostgrestException>()),
            reason: table,
          );
          await expectLater(
            user.from(table).insert({'gtin14': other, 'sha256': 'a' * 64, 'object_path': 'x'}),
            throwsA(isA<PostgrestException>()),
            reason: table,
          );
        }
        await expectLater(
          user.rpc('barcode_catalogue_request_share', params: {
            'p_body': {'gtin14': other},
          }),
          throwsA(isA<PostgrestException>()),
        );
        await expectLater(
          user.rpc('barcode_catalogue_photo_candidates', params: {'p_gtin14': other}),
          throwsA(isA<PostgrestException>()),
        );
      },
      skip: _skipReason,
    );
  });
}

/// GS1 mod-10 on the full code (check digit included).
bool _checkDigitOk(String code) {
  var sum = 0;
  for (var i = 0; i < code.length; i++) {
    final digit = code.codeUnitAt(code.length - 1 - i) - 48;
    sum += i.isOdd ? digit * 3 : digit;
  }
  return sum % 10 == 0;
}
