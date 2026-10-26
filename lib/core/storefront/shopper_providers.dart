import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/core/storefront/shopper_session.dart';

/// The signed-in Shopper's commands (#426). Overridden in tests.
final shopperServiceProvider = Provider<ShopperService>(
  (ref) => ShopperService(ref.read(supabaseClientProvider)),
);

/// The Shopper's details; null before the first-time details. Reloads when
/// the signed-in login changes.
final shopperProfileProvider = FutureProvider.autoDispose<ShopperProfile?>((
  ref,
) async {
  final session = ref.watch(shopperSessionProvider);
  if (!session.isSignedIn) return null;
  return ref.read(shopperServiceProvider).profile();
});

/// My Orders: the Shopper's own Online Orders, newest first.
final shopperOrdersProvider = FutureProvider.autoDispose<List<ShopperOrder>>((
  ref,
) async {
  final session = ref.watch(shopperSessionProvider);
  if (!session.isSignedIn) return const [];
  return ref.read(shopperServiceProvider).myOrders();
});

/// Writes the Shopper's export as a `.json` file and opens the share sheet
/// (#477). Overridden in tests. Reuses `path_provider` + `share_plus`.
typedef ShopperExportSharer = Future<void> Function(Map<String, Object?> data);

Future<void> shareShopperExport(Map<String, Object?> data) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/my-reebaplus-data.json');
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  await Share.shareXFiles([
    XFile(file.path, mimeType: 'application/json'),
  ], subject: 'My Reebaplus data');
}

final shopperExportSharerProvider = Provider<ShopperExportSharer>(
  (ref) => shareShopperExport,
);
