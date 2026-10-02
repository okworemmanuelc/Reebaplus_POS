import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/providers/pos_providers.dart';

/// The scanner's running "‹N› items in cart" pill (#319), live from the cart:
/// units (sum of line quantities), not lines and not money.
class ScanCartCount extends ConsumerWidget {
  const ScanCartCount({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = scanCartCountLabel(ref.watch(cartUnitCountProvider));
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(8),
      ),
      decoration: BoxDecoration(
        // Over the live camera, so a fixed dark scrim in both themes.
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: Colors.white),
      ),
    );
  }
}

/// "3 items in cart", "1 item in cart", "1.5 items in cart" — no trailing
/// `.0` on whole quantities.
String scanCartCountLabel(double units) {
  final n = units == units.truncateToDouble()
      ? units.toInt().toString()
      : units.toString();
  return '$n ${units == 1 ? 'item' : 'items'} in cart';
}
