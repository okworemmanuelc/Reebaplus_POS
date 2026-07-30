import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/record_driver_payment_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// Driver payments (#144, PRD #139 / ADR 0019 decision 2, van-sales spec §5.3).
///
/// One trip's money story: what the driver signed for, what they have handed
/// in, and what is still out. Recording a payment from here writes **both**
/// legs in one transaction — the driver-ledger credit that moves the balance,
/// and a `van_remittance` payment row that puts the cash into the business's
/// books on the day it arrived.
///
/// Gated `Gates.vanManage` throughout: the drawer entry, the hub that pushes
/// this screen, the body guard below, and the sheet's fire-time re-check. A
/// Driver-role user holds `van.sell` and never `van.manage`, so "the driver
/// records their own payment" is impossible by construction (spec §9.5 #21).
class DriverPaymentsScreen extends ConsumerWidget {
  final String tripId;
  final String driverName;
  final String vanName;

  const DriverPaymentsScreen({
    super.key,
    required this.tripId,
    required this.driverName,
    required this.vanName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Body guard (layer 2, hard rule #6): the hub already hides the way in, but
    // a live revocation while this screen is open must empty it too.
    if (!Gates.vanManage.allows(ref)) {
      return GlassyScaffold(
        title: 'Driver Payments',
        body: _Empty(
          icon: FontAwesomeIcons.lock.data,
          title: 'No access',
          message: 'You no longer have access to Van Sales.',
        ),
      );
    }

    final trip = ref.watch(vanTripProvider(tripId)).valueOrNull;
    final entries =
        ref.watch(vanTripLedgerProvider(tripId)).valueOrNull ??
        const <DriverLedgerEntryData>[];
    final balanceKobo = trip == null
        ? null
        : ref.watch(driverBalanceProvider(trip.driverUserId)).valueOrNull;

    return GlassyScaffold(
      title: 'Driver Payments',
      subtitle: '$driverName • $vanName',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20) + context.deviceBottomPadding,
        ),
        children: [
          _BalanceCard(balanceKobo: balanceKobo),
          SizedBox(height: context.getRSize(16)),
          if (trip != null && trip.status == kVanTripStatusOpen)
            Guarded(
              gate: Gates.vanManage,
              builder: (context, allow) => SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: allow(
                    () => RecordDriverPaymentSheet.show(
                      context,
                      trip: trip,
                      driverName: driverName,
                    ),
                  ),
                  icon: Icon(
                    FontAwesomeIcons.moneyBillTransfer.data,
                    size: context.getRSize(14),
                  ),
                  label: const Text('Record payment'),
                ),
              ),
            )
          else if (trip != null)
            Text(
              // Honest about the boundary: a closed trip is never edited in
              // place, and the residual has moved to the driver's cross-trip
              // balance (spec §9.4 #14/#16).
              'This trip is closed. Anything still owed sits on '
              '$driverName\'s balance and is settled on their next trip.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
          SizedBox(height: context.getRSize(24)),
          Text(
            'Trip activity',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: context.getRSize(12)),
          if (entries.isEmpty)
            _Empty(
              icon: FontAwesomeIcons.receipt.data,
              title: 'Nothing recorded yet',
              message: 'Loads and payments on this trip will show here.',
            )
          else
            for (final e in entries) ...[
              _LedgerRow(entry: e),
              SizedBox(height: context.getRSize(10)),
            ],
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final int? balanceKobo;

  const _BalanceCard({required this.balanceKobo});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final owed = balanceKobo ?? 0;
    final color = owed < 0
        ? t.colorScheme.error
        : owed == 0
        ? semantic.success
        : semantic.info;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(18)),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            owed < 0
                ? 'Still owed'
                : owed == 0
                ? 'Settled'
                : 'In credit',
            style: t.textTheme.bodySmall?.copyWith(
              color: t.textTheme.bodySmall?.color,
            ),
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            formatCurrency((owed < 0 ? -owed : owed) / 100),
            style: t.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// One driver-ledger row: what happened, when, and which way the money moved.
class _LedgerRow extends StatelessWidget {
  final DriverLedgerEntryData entry;

  const _LedgerRow({required this.entry});

  /// Shop-owner words for a ledger type — never the raw enum.
  static String _label(DriverLedgerEntryData e) {
    switch (e.type) {
      case kDriverLedgerTypeLoad:
        return 'Loaded onto the van';
      case kDriverLedgerTypeRestock:
        return 'Restocked on the road';
      case kDriverLedgerTypeReturnGood:
        return 'Returned in good condition';
      case kDriverLedgerTypePaymentCash:
        return 'Cash handed in';
      case kDriverLedgerTypePaymentTransfer:
        return 'Payment handed in';
      case kDriverLedgerTypeShortageWriteoff:
        return 'Shortage written off';
      case kDriverLedgerTypeDamageWriteoff:
        return 'Damage written off';
      case kDriverLedgerTypeRestatement:
        return 'Corrected after close';
      case kDriverLedgerTypeVoid:
        return 'Reversed';
      default:
        return e.type;
    }
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final isCredit = entry.signedAmountKobo > 0;
    final voided = entry.voidedAt != null;
    final color = voided
        ? subtext
        : isCredit
        ? semantic.success
        : t.colorScheme.error;

    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.dividerColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(entry),
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    decoration: voided ? TextDecoration.lineThrough : null,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  [
                    _date(entry.activityDate),
                    if (entry.paymentMethod != null) entry.paymentMethod!,
                    if ((entry.referenceNote ?? '').isNotEmpty)
                      entry.referenceNote!,
                  ].join(' • '),
                  style: t.textTheme.bodySmall?.copyWith(color: subtext),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(10)),
          Text(
            '${isCredit ? '+' : '−'}'
            '${formatCurrency(entry.amountKobo / 100)}',
            style: t.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
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
