import 'package:flutter_riverpod/flutter_riverpod.dart';

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
