import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_terminal_screen.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// The driver's **read-only** view of their own run (#142, spec §9.2).
///
/// Three numbers and a list: what they have taken on the road, what they still
/// owe, and every sale they rang. Read-only is the whole design — a driver has
/// no surface here to load a van, record a payment against themselves, or
/// reconcile, and `Gates.vanManage` (which they do not hold) backs that up at
/// every write boundary (spec §9.5 #21).
///
/// The two money figures are deliberately DIFFERENT things and are labelled so:
///
///  * **Taken on the road** is `soldValue` — road takings at load price. It is
///    NOT cash in the business. A road sale writes no payment row (ADR 0019
///    decision 2); the money is in the driver's custody until a manager records
///    the remittance.
///  * **You owe** is the driver's cross-trip ledger balance —
///    `loaded − returned − paid`. A sale does not move it, which is exactly why
///    it stays a clean measure of what the driver signed for and has not yet
///    settled.
class DriverRunScreen extends ConsumerWidget {
  final String tripId;

  const DriverRunScreen({super.key, required this.tripId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Body guard (hard rule #6): a live revocation while this screen is open
    // must empty it, not just hide the way in.
    if (!Gates.vanSell.allows(ref)) {
      return GlassyScaffold(
        title: 'My run',
        body: _Empty(
          icon: FontAwesomeIcons.lock.data,
          title: 'No access',
          message: 'You no longer have access to van sales.',
        ),
      );
    }

    final trip = ref.watch(vanTripProvider(tripId)).valueOrNull;
    final sales =
        ref.watch(vanTripSalesProvider(tripId)).valueOrNull ??
        const <OrderData>[];
    final soldKobo = ref.watch(vanTripSoldValueProvider(tripId)).valueOrNull ?? 0;
    final balanceKobo = trip == null
        ? 0
        : ref.watch(driverBalanceProvider(trip.driverUserId)).valueOrNull ?? 0;

    final recognised = [
      for (final o in sales)
        if (orderCountsAsSale(o.status)) o,
    ];

    return GlassyScaffold(
      title: 'My run',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20) + context.deviceBottomPadding,
        ),
        children: [
          _TakenCard(soldKobo: soldKobo, saleCount: recognised.length),
          SizedBox(height: context.getRSize(14)),
          Center(child: BalancePill(balanceKobo: balanceKobo)),
          SizedBox(height: context.getRSize(10)),
          Text(
            // The honest sentence. Without it a driver reads "taken ₦X" and
            // "you owe ₦Y" as a contradiction rather than two stages of the
            // same money.
            'Cash you take on the road stays yours to hand in — it only comes '
            'off what you owe once a manager records the payment.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
          SizedBox(height: context.getRSize(24)),
          Text(
            'Sales on this run',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: context.getRSize(12)),
          if (sales.isEmpty)
            _Empty(
              icon: FontAwesomeIcons.receipt.data,
              title: 'No sales yet',
              message: 'Every sale you ring on this run will show here.',
            )
          else
            for (final o in sales) ...[
              _SaleRow(order: o),
              SizedBox(height: context.getRSize(10)),
            ],
        ],
      ),
    );
  }
}

class _TakenCard extends StatelessWidget {
  final int soldKobo;
  final int saleCount;

  const _TakenCard({required this.soldKobo, required this.saleCount});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(18)),
      decoration: BoxDecoration(
        color: semantic.success.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Taken on the road',
            style: t.textTheme.bodySmall?.copyWith(
              color: t.textTheme.bodySmall?.color,
            ),
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            formatCurrency(soldKobo / 100),
            style: t.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: semantic.success,
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            saleCount == 1 ? '1 sale' : '$saleCount sales',
            style: t.textTheme.bodySmall?.copyWith(
              color: t.textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }
}

class _SaleRow extends StatelessWidget {
  final OrderData order;

  const _SaleRow({required this.order});

  static String _time(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final reversed = !orderCountsAsSale(order.status);
    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(color: t.dividerColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.orderNumber,
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    decoration: reversed ? TextDecoration.lineThrough : null,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  reversed
                      ? '${_time(order.createdAt)} • cancelled'
                      : _time(order.createdAt),
                  style: t.textTheme.bodySmall?.copyWith(color: subtext),
                ),
              ],
            ),
          ),
          Text(
            formatCurrency(order.netAmountKobo / 100),
            style: t.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: reversed ? subtext : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String message;

  const _Empty({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Padding(
      padding: EdgeInsets.all(context.getRSize(28)),
      child: Column(
        children: [
          Icon(icon, size: context.getRSize(36), color: subtext),
          SizedBox(height: context.getRSize(12)),
          Text(
            title,
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            message,
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: subtext),
          ),
        ],
      ),
    );
  }
}
