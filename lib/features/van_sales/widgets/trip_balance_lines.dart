import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// "Owes ₦X" for a debt, "In credit ₦X" when the shop owes the driver.
String owedLabel(int owedKobo) => owedKobo >= 0
    ? formatCurrency(owedKobo / 100)
    : 'In credit ${formatCurrency(-owedKobo / 100)}';

/// What one open trip still owes, as a single "This trip" line. Shown
/// wherever a manager takes money from a driver (#800). The owner dropped the
/// "Balance before this trip" and "Total owed now" lines on 2026-11-14 (#820):
/// only this trip's figure is shown. Renders nothing until the figure loads.
class TripBalanceLines extends ConsumerWidget {
  final String tripId;

  const TripBalanceLines({super.key, required this.tripId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(vanTripPositionProvider(tripId)).valueOrNull;
    if (position == null) return const SizedBox.shrink();
    final owed = position.outstandingKobo;
    return _line(
      context,
      'This trip',
      owedLabel(owed),
      strong: true,
      color: owed > 0 ? Theme.of(context).colorScheme.error : null,
    );
  }

  Widget _line(
    BuildContext context,
    String label,
    String value, {
    bool strong = false,
    Color? color,
  }) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(3)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: (strong ? t.textTheme.bodyMedium : t.textTheme.bodySmall)
                  ?.copyWith(
                    color: strong
                        ? (color ?? t.colorScheme.onSurface)
                        : subtext,
                    fontWeight: strong ? FontWeight.w700 : null,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: context.getRSize(10)),
          Text(
            value,
            textAlign: TextAlign.right,
            style: (strong ? t.textTheme.titleMedium : t.textTheme.bodySmall)
                ?.copyWith(
                  color: color ?? t.colorScheme.onSurface,
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}
