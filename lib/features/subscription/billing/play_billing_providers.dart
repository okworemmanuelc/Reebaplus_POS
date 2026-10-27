import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_controller.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_port.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';

/// True only on the Android app, where Google Play Billing exists.
final billingSupportedProvider = Provider<bool>(
  (_) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
);

final playBillingPortProvider = Provider<PlayBillingPort>(
  (_) => InAppPurchasePort(),
);

final purchaseVerifierProvider = Provider<PurchaseVerifier>(
  (ref) => supabasePurchaseVerifier(ref.watch(supabaseClientProvider)),
);

/// The business a purchase is bound to (sent as the Play obfuscated account id).
final billingBusinessIdProvider = Provider<String?>(
  (ref) => ref.watch(currentBusinessProvider)?.id,
);

/// Naira fallback prices for Nigerian (NGN) businesses, dollars otherwise.
final billingUsesNairaProvider = Provider<bool>(
  (ref) => pricesInNaira(ref.watch(currencyCodeProvider).valueOrNull),
);
