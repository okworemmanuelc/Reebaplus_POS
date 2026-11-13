import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The three figures behind a driver's balance while a trip is out (#800).
///
/// [totalBalanceKobo] is the driver's whole ledger balance (negative = owes)
/// and [tripOutstandingKobo] is what THIS trip still owes (positive = owed,
/// `VanTripPosition.outstandingKobo`). What is left over is the balance the
/// driver carried from outside this trip: earlier trips, and payments or
/// account entries recorded on no trip.
class TripBalanceSplit {
  final int beforeOwedKobo;
  final int tripOwedKobo;
  final int totalOwedKobo;

  const TripBalanceSplit._({
    required this.beforeOwedKobo,
    required this.tripOwedKobo,
    required this.totalOwedKobo,
  });

  factory TripBalanceSplit({
    required int totalBalanceKobo,
    required int tripOutstandingKobo,
  }) {
    final total = -totalBalanceKobo;
    return TripBalanceSplit._(
      beforeOwedKobo: total - tripOutstandingKobo,
      tripOwedKobo: tripOutstandingKobo,
      totalOwedKobo: total,
    );
  }
}

/// "Owes ₦X" for a debt, "In credit ₦X" when the shop owes the driver.
String owedLabel(int owedKobo) => owedKobo >= 0
    ? formatCurrency(owedKobo / 100)
    : 'In credit ${formatCurrency(-owedKobo / 100)}';

/// Balance before this trip / This trip / Total owed now, for one open trip
/// (#800). Shown wherever a manager takes money from a driver, so nobody has
/// to add the figures up by hand. Renders nothing until both figures load.
class TripBalanceLines extends ConsumerWidget {
  final String tripId;

  const TripBalanceLines({super.key, required this.tripId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = ref.watch(tripOwnerBalanceProvider(tripId)).valueOrNull;
    final position = ref.watch(vanTripPositionProvider(tripId)).valueOrNull;
    if (total == null || position == null) return const SizedBox.shrink();
    final split = TripBalanceSplit(
      totalBalanceKobo: total,
      tripOutstandingKobo: position.outstandingKobo,
    );
    final t = Theme.of(context);
    final owes = split.totalOwedKobo > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(
          context,
          'Balance before this trip',
          owedLabel(split.beforeOwedKobo),
        ),
        _line(context, 'This trip', owedLabel(split.tripOwedKobo)),
        _line(
          context,
          split.totalOwedKobo < 0 ? 'Total now' : 'Total owed now',
          owedLabel(split.totalOwedKobo),
          strong: true,
          color: owes ? t.colorScheme.error : null,
        ),
      ],
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
