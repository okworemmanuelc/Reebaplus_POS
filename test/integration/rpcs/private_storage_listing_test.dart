@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _env = Platform.environment;
final _skip = ['TEST_SUPABASE_URL', 'TEST_SUPABASE_ANON_KEY',
  'TEST_SUPABASE_SERVICE_ROLE_KEY'].any((key) => _env[key]?.isNotEmpty != true)
    ? 'Storage isolation needs TEST_SUPABASE_URL, ANON_KEY and SERVICE_ROLE_KEY.'
    : _env['TEST_STORAGE_ISOLATION_ALLOW_WRITES'] != '1'
        ? 'Set TEST_STORAGE_ISOLATION_ALLOW_WRITES=1 on reebaplus-dev.' : null;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  late SupabaseClient admin;
  late SupabaseClient owner;
  late SupabaseClient outsider;
  late SupabaseClient anon;
  final authIds = <String>[];
  final businessId = UuidV7.generate();
  var createdBusiness = false;
  var initialized = false;
  final paths = <String, String>{
    'product-images': '$businessId/${UuidV7.generate()}.png',
    'business-logos': '$businessId.png',
  };
  final newPaths = <String, String>{
    'product-images': '$businessId/${UuidV7.generate()}.png',
    'business-logos': '$businessId.jpg',
  };

  Future<void> createLogin(SupabaseClient client) async {
    final email = 'storage-${UuidV7.generate()}@example.com';
    final password = '${UuidV7.generate()}Aa1!';
    final result = await admin.auth.admin.createUser(AdminUserAttributes(
      email: email, password: password, emailConfirm: true,
    ));
    authIds.add(result.user!.id);
    await client.auth.signInWithPassword(email: email, password: password);
  }

  setUpAll(() async {
    if (_skip != null) return;
    final url = _env['TEST_SUPABASE_URL']!;
    if (url != 'https://yngwzuinxhxhzdfagcbg.supabase.co') {
      throw StateError('Fixture writes require the approved reebaplus-dev URL.');
    }
    admin = SupabaseClient(url, _env['TEST_SUPABASE_SERVICE_ROLE_KEY']!);
    final key = _env['TEST_SUPABASE_ANON_KEY']!;
    owner = SupabaseClient(url, key);
    outsider = SupabaseClient(url, key);
    anon = SupabaseClient(url, key);
    initialized = true;
    await createLogin(owner);
    await createLogin(outsider);
    await admin.from('businesses').insert({
      'id': businessId, 'name': 'Storage isolation test', 'owner_id': authIds.first,
    });
    createdBusiness = true;
    await admin.from('profiles').upsert({
      'id': authIds.first, 'business_id': businessId, 'name': 'Storage owner',
    });
    expect(await owner.rpc('current_user_business_ids'), contains(businessId));
    expect(await outsider.rpc('current_user_business_ids'), isEmpty);
    // Seed real objects first: denial cannot pass just because a bucket is empty.
    for (final entry in paths.entries) {
      await admin.storage.from(entry.key).uploadBinary(entry.value, _png,
        fileOptions: const FileOptions(contentType: 'image/png', upsert: true));
    }
  });

  tearDownAll(() async {
    if (!initialized) return;
    // Register cleanup before setup finishes; attempt every fixture even after
    // an upload or assertion fails. Never touch pre-existing object paths.
    Future<void> cleanup(Future<void> Function() action) async {
      try { await action(); } on Object catch (error) {
        printOnFailure('Storage fixture cleanup failed: $error');
      }
    }
    for (final entry in paths.entries) {
      await cleanup(() async {
        await admin.storage.from(entry.key).remove([entry.value, newPaths[entry.key]!]);
      });
    }
    for (final id in authIds) {
      await cleanup(() async { await admin.from('profiles').delete().eq('id', id); });
    }
    if (createdBusiness) {
      await cleanup(() async { await admin.from('businesses').delete().eq('id', businessId); });
    }
    for (final id in authIds) {
      await cleanup(() async { await admin.auth.admin.deleteUser(id); });
    }
    for (final client in [owner, outsider, anon, admin]) { await client.dispose(); }
  });

  for (final bucket in ['product-images', 'business-logos']) {
    final prefix = bucket == 'product-images' ? businessId : '';
    test('$bucket: owner lists and replaces; strangers cannot enumerate', () async {
      final path = paths[bucket]!;
      final name = path.split('/').last;
      expect((await owner.storage.from(bucket).list(path: prefix)).map((f) => f.name),
        contains(name));
      for (final client in [anon, outsider]) {
        // Test both root enumeration and a known tenant prefix.
        for (final directory in {'', prefix}) {
          try {
            expect(await client.storage.from(bucket).list(path: directory), isEmpty);
          } on StorageException catch (error) {
            expect(error.statusCode, anyOf('401', '403'), reason: error.message);
          }
        }
      }
      final uploadedPath = newPaths[bucket]!;
      await owner.storage.from(bucket).uploadBinary(uploadedPath, _png,
        fileOptions: const FileOptions(contentType: 'image/png', upsert: true));
      final replacement = Uint8List.fromList([..._png, 1]);
      await owner.storage.from(bucket).uploadBinary(uploadedPath, replacement,
        fileOptions: const FileOptions(contentType: 'image/png', upsert: true));
      // Use raw HTTP without API key or bearer token, as cached public URLs do.
      final http = HttpClient();
      try {
        final url = anon.storage.from(bucket).getPublicUrl(uploadedPath);
        final response = await (await http.getUrl(Uri.parse('$url?v=${UuidV7.generate()}'))).close();
        expect(response.statusCode, 200);
        final bytes = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
        expect(bytes, replacement);
      } finally { http.close(); }
    }, skip: _skip);
  }
}
