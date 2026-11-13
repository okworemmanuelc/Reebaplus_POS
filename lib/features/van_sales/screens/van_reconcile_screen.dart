import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/industry/lexicon.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/van_sales/van_trip_position.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_return_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/record_driver_payment_sheet.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/trip_balance_lines.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_close_barrier.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_ui.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_write_off_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// Reconcile & close — the heart of van sales (#145, PRD #139 / ADR 0019,
/// van-sales spec §5.5, §6, §7, §9.4, §11).
///
/// The screen shows the WHOLE position at load price, computed by the pure
/// [computeVanTripPosition] rather than assembled here, so the figure a manager
/// confirms against is provably the figure [VanTripsDao.closeTrip] writes.
///
/// The order of what it shows is the order a manager thinks in:
///
///  1. **What is still owed**, split three ways — unremitted cash, shortage,
///     damage. "The driver owes ₦192,500" is the question; this is the answer
///     to *why*.
///  2. **What went out and what came back**, so the split is checkable.
///  3. **Which goods are missing**, per product, at the prices they left on.
///  4. **The shells** — loaded with N, M came back (spec §11). Without this a
///     trip closes at "balance 0 = settled" having lost every crate. Shown only
///     to a crate business; empties are a Bar/Beverage concept.
///  5. **The four things a manager can still do**: log the final return, record
///     a final payment, write off a shortage or a damage.
///  6. **Confirm & close**, which is *disabled* while this device still has
///     road sales in its outbox — you do not assign blame from an incomplete
///     picture. [VanCloseBarrier] owns that rule and the explicit "Close
///     anyway" override behind it (#208 item 5, spec §7.4).
///
/// Gated `Gates.vanManage` at the drawer, the hub, this body, and every write's
/// fire time. A Driver holds `van.sell` and never this (spec §9.5 #21).
class VanReconcileScreen extends ConsumerWidget {
  final String tripId;
  final String driverName;
  final String vanName;

  const VanReconcileScreen({
    super.key,
    required this.tripId,
    required this.driverName,
    required this.vanName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Body guard (layer 2, hard rule #6): the hub hides the way in, but a live
    // revocation while this screen is open must empty it too.
    if (!Gates.vanManage.allows(ref)) {
      return const GlassyScaffold(
        title: 'Reconcile & close',
        body: _Empty(
          icon: AppIcons.lock,
          title: 'No access',
          message: 'You no longer have access to Van Sales.',
        ),
      );
    }

    final trip = ref.watch(vanTripProvider(tripId)).valueOrNull;
    final position = ref.watch(vanTripPositionProvider(tripId)).valueOrNull;
    final pendingSales =
        ref.watch(vanTripPendingSalesProvider(tripId)).valueOrNull ?? 0;
    // The trade's own word for a sellable item (ADR 0015) — this screen names
    // what is missing and what was damaged, so it must not call a pharmacy's
    // stock "drinks". Threaded into the cards rather than read in each one, so
    // every figure on the screen is captioned from the same source.
    final lex = ref.watch(industryLexiconProvider);
    // The shell memo is a Bar/Beverage surface only.
    final tracksCrates = businessTracksCrates(
      ref.watch(currentBusinessProvider),
    );
    // Names for the shortage lines. Same feed the return screen uses, so one
    // product reads the same on both surfaces.
    final productName = <String, String>{
      for (final p
          in ref.watch(productsWithStockProvider(null)).valueOrNull ??
              const <ProductDataWithStock>[])
        p.product.id: p.product.name,
    };

    if (trip == null || position == null) {
      return GlassyScaffold(
        title: 'Reconcile & close',
        subtitle: '$driverName • $vanName',
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final isOpen = trip.status == kVanTripStatusOpen;

    final list = ListView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(20),
        context.getRSize(20),
        context.getRSize(20) + (isOpen ? 0 : context.deviceBottomPadding),
      ),
      children: [
        _OutstandingCard(position: position, lex: lex),
        SizedBox(height: context.getRSize(16)),
        _Card(child: TripBalanceLines(tripId: tripId)),
        SizedBox(height: context.getRSize(16)),
        _MovementCard(position: position, lex: lex),
        if (position.shortages.isNotEmpty) ...[
          SizedBox(height: context.getRSize(16)),
          _ShortageCard(position: position, productName: productName, lex: lex),
        ],
        if (tracksCrates) ...[
          SizedBox(height: context.getRSize(16)),
          _ShellMemoCard(position: position),
        ],
        if (position.hasUncostedUnits) ...[
          SizedBox(height: context.getRSize(16)),
          _UncostedCard(position: position, lex: lex),
        ],
        SizedBox(height: context.getRSize(20)),
        if (isOpen)
          _actions(context, ref, trip, position)
        else
          _ClosedCard(trip: trip, driverName: driverName, lex: lex),
      ],
    );

    return GlassyScaffold(
      title: 'Reconcile & close',
      subtitle: '$driverName • $vanName',
      body: isOpen
          ? Column(
              children: [
                Expanded(child: list),
                // The one primary action stays pinned above the system inset.
                _PinnedClose(
                  child: VanCloseBarrier(
                    pendingSales: pendingSales,
                    lex: lex,
                    onClose: () => _confirmAndClose(
                      context,
                      ref,
                      trip: trip,
                      position: position,
                      pendingSales: pendingSales,
                    ),
                  ),
                ),
              ],
            )
          : list,
    );
  }

  Widget _actions(
    BuildContext context,
    WidgetRef ref,
    VanTripData trip,
    VanTripPosition position,
  ) {
    final gap = SizedBox(width: context.getRSize(10));
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: VanTonalButton(
                icon: AppIcons.undo,
                label: 'Final return',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => VanReturnScreen(
                      trip: trip,
                      driverName: driverName,
                      vanName: vanName,
                    ),
                  ),
                ),
              ),
            ),
            gap,
            Expanded(
              child: VanTonalButton(
                icon: AppIcons.transfer,
                label: 'Final payment',
                onPressed: () => RecordDriverPaymentSheet.show(
                  context,
                  trip: trip,
                  driverName: driverName,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(10)),
        // Write-offs are the deliberate escape hatch: shortage and damage stay
        // driver-liable until somebody decides otherwise, on the record.
        Row(
          children: [
            Expanded(
              child: VanTonalButton(
                icon: AppIcons.zoomOut,
                label: 'Write off shortage',
                onPressed: position.shortageOwedKobo <= 0
                    ? null
                    : () => VanWriteOffSheet.show(
                        context,
                        trip: trip,
                        driverName: driverName,
                        type: kDriverLedgerTypeShortageWriteoff,
                        owedKobo: position.shortageOwedKobo,
                      ),
              ),
            ),
            gap,
            Expanded(
              child: VanTonalButton(
                icon: AppIcons.wineBottle,
                label: 'Write off damage',
                onPressed: position.damageOwedKobo <= 0
                    ? null
                    : () => VanWriteOffSheet.show(
                        context,
                        trip: trip,
                        driverName: driverName,
                        type: kDriverLedgerTypeDamageWriteoff,
                        owedKobo: position.damageOwedKobo,
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// The last gate before the artifact is frozen.
  ///
  /// The dialog restates the facts a manager must not close without having
  /// seen: the shell memo (spec §11 — crate businesses only, since no other
  /// trade has empties to lose), the residual that will follow the driver
  /// rather than the trip (§9.4 #14), and — when this device still holds
  /// un-pushed road sales — that the picture may be incomplete (§7.4).
  ///
  /// When the outbox is dirty this dialog **is** the override confirmation
  /// [VanCloseBarrier] hands off to (#208 item 5): the title asks the real
  /// question, the outbox paragraph leads instead of trailing, and the
  /// affirmative action is labelled "Close anyway" so the manager is agreeing
  /// to the risk rather than dismissing a notice. A second dialog stacked on
  /// this one would be noise — it is the same decision, asked twice.
  Future<void> _confirmAndClose(
    BuildContext context,
    WidgetRef ref, {
    required VanTripData trip,
    required VanTripPosition position,
    required int pendingSales,
  }) async {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final lex = ref.read(industryLexiconProvider);
    // Same gate as the body's shell memo card — a trade that deals in no
    // empties is not asked to confirm a shell count before closing.
    final tracksCrates = businessTracksCrates(
      ref.read(currentBusinessProvider),
    );
    final overriding = pendingSales > 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          overriding ? 'Close on an incomplete picture?' : 'Close this trip?',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Leads when it applies: the manager is being asked to accept this,
            // not to notice it on the way past.
            if (overriding) ...[
              Text(
                '$pendingSales road '
                '${pendingSales == 1 ? 'sale has' : 'sales have'} not synced '
                'from this device yet. Until they go up those '
                '${lex.itemPluralLower} count as missing and $driverName looks '
                'liable for them — so this settles on an incomplete picture.',
                style: t.textTheme.bodyMedium?.copyWith(
                  color: semantic.warning,
                ),
              ),
              SizedBox(height: context.getRSize(10)),
              Text(
                'Waiting for the sync to clear is the safer answer. Closing now '
                'is allowed because sync can stay down for days: a sale that '
                'arrives later posts its own correction to $driverName\'s '
                'balance rather than reopening the trip.',
                style: t.textTheme.bodySmall?.copyWith(color: t.hintColor),
              ),
              SizedBox(height: context.getRSize(10)),
            ],
            if (tracksCrates) ...[
              Text(
                'Loaded with ${position.shellsOut} '
                '${position.shellsOut == 1 ? 'shell' : 'shells'}, '
                '${position.shellsBack} empties came back.'
                '${position.hasShellLoss ? ' Lost crates: ${position.shellsLostUnits}'
                          '${position.shellsLostValueKobo > 0 ? ' (${formatCurrency(position.shellsLostValueKobo / 100)})' : ''}'
                          ' — not charged.' : ''}',
                style: t.textTheme.bodyMedium,
              ),
              SizedBox(height: context.getRSize(10)),
            ],
            Text(
              position.isSettled
                  ? 'The trip is settled — it will close at zero.'
                  : position.outstandingKobo > 0
                  ? '${formatCurrency(position.outstandingKobo / 100)} is still '
                        'owed. Closing is allowed: the balance follows '
                        '$driverName to their next trip.'
                  : '$driverName is in credit '
                        '${formatCurrency(-position.outstandingKobo / 100)}. '
                        'That credit follows them to their next trip.',
              style: t.textTheme.bodyMedium,
            ),
            SizedBox(height: context.getRSize(10)),
            Text(
              'Once closed the trip cannot be edited — any correction after '
              'this is a new entry on $driverName\'s balance.',
              style: t.textTheme.bodySmall?.copyWith(
                color: t.textTheme.bodySmall?.color,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(overriding ? 'Wait for sync' : 'Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: overriding
                ? FilledButton.styleFrom(backgroundColor: semantic.warning)
                : null,
            child: Text(overriding ? 'Close anyway' : 'Close trip'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    // Write-boundary re-check (ADR 0002 layer 3).
    if (!Gates.vanManage.allowsNow(ref)) {
      showGateDenied(context, Gates.vanManage);
      return;
    }
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null) {
      AppNotification.showError(
        context,
        'Cannot close yet — your account is still loading. Try again in a '
        'moment.',
      );
      return;
    }

    try {
      final result = await ref
          .read(databaseProvider)
          .vanTripsDao
          .closeTrip(tripId: trip.id, performedBy: staffId);
      if (!context.mounted) return;
      AppNotification.showSuccess(
        context,
        result.closedWithBalance
            ? 'Trip closed. '
                  '${formatCurrency(result.position.outstandingKobo.abs() / 100)} '
                  'carried to $driverName\'s balance.'
            : 'Trip closed and settled.',
      );
    } on VanTripNotOpenException catch (e) {
      if (!context.mounted) return;
      AppNotification.showError(context, e.message);
    } catch (_) {
      if (!context.mounted) return;
      AppNotification.showError(context, 'Could not close the trip.');
    }
  }
}

/// The headline: what is still owed, and why.
class _OutstandingCard extends StatelessWidget {
  final VanTripPosition position;
  final Lexicon lex;

  const _OutstandingCard({required this.position, required this.lex});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final owed = position.outstandingKobo;
    final color = owed > 0
        ? t.colorScheme.error
        : owed == 0
        ? semantic.success
        : semantic.info;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            owed > 0
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
            formatCurrency(owed.abs() / 100),
            style: t.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          SizedBox(height: context.getRSize(14)),
          _Row(
            label: 'Cash not handed in',
            value: formatCurrency(position.unremittedCashKobo / 100),
          ),
          _Row(
            label: '${lex.itemPlural} unaccounted for',
            value: formatCurrency(position.shortageOwedKobo / 100),
          ),
          _Row(
            label: 'Damaged ${lex.itemPluralLower}',
            value: formatCurrency(position.damageOwedKobo / 100),
          ),
          if (position.residualCreditKobo > 0)
            _Row(
              label: 'Paid over',
              value: formatCurrency(position.residualCreditKobo / 100),
            ),
          if (position.shortageWriteoffKobo > 0 ||
              position.damageWriteoffKobo > 0) ...[
            SizedBox(height: context.getRSize(6)),
            _Row(
              label: 'Already written off',
              value: formatCurrency(
                (position.shortageWriteoffKobo + position.damageWriteoffKobo) /
                    100,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What went out and what came back — the arithmetic behind the split, at load
/// price throughout so every line is comparable.
class _MovementCard extends StatelessWidget {
  final VanTripPosition position;
  final Lexicon lex;

  const _MovementCard({required this.position, required this.lex});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The run, at load price',
            style: t.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: context.getRSize(12)),
          _Row(
            label: 'Loaded + restocked (${position.loadedUnits})',
            value: formatCurrency(position.loadedValueKobo / 100),
            strong: true,
          ),
          _Row(
            label: 'Sold on the road (${position.soldUnits})',
            value: formatCurrency(position.soldValueKobo / 100),
          ),
          _Row(
            label: 'Returned in good order (${position.goodReturnedUnits})',
            value: formatCurrency(position.goodReturnValueKobo / 100),
          ),
          _Row(
            label: 'Returned damaged (${position.damagedUnits})',
            value: formatCurrency(position.damageValueKobo / 100),
          ),
          // Selling through the app is optional, so these units are not
          // presumed lost: the cash the driver hands in pays for them.
          _Row(
            label: 'Not returned (${position.shortageUnits})',
            value: formatCurrency(position.shortageValueKobo / 100),
          ),
          Divider(color: t.dividerColor, height: context.getRSize(22)),
          _Row(
            label: 'Handed in so far',
            value: formatCurrency(position.remittedKobo / 100),
            strong: true,
          ),
          if (position.rungValueKobo != position.soldValueKobo) ...[
            SizedBox(height: context.getRSize(8)),
            Text(
              // Spec §9.2 #9 — the markup is the driver's and is not recorded.
              // Saying so is better than a silent discrepancy.
              'The terminal rang '
              '${formatCurrency(position.rungValueKobo / 100)}; the '
              'reconciliation values the ${lex.itemPluralLower} at what was '
              'signed for.',
              style: t.textTheme.bodySmall?.copyWith(color: t.hintColor),
            ),
          ],
        ],
      ),
    );
  }
}

/// Which goods are missing, and at what price they left.
class _ShortageCard extends StatelessWidget {
  final VanTripPosition position;
  final Map<String, String> productName;
  final Lexicon lex;

  const _ShortageCard({
    required this.position,
    required this.productName,
    required this.lex,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${lex.itemPlural} that never came back',
            style: t.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: context.getRSize(12)),
          for (final line in position.shortages)
            _Row(
              label:
                  '${productName[line.productId] ?? lex.item} × ${line.units}',
              value: formatCurrency(line.valueKobo / 100),
            ),
          SizedBox(height: context.getRSize(8)),
          Text(
            'Valued at the price they were loaded at. The driver stays liable '
            'unless you write it off.',
            style: t.textTheme.bodySmall?.copyWith(color: t.hintColor),
          ),
        ],
      ),
    );
  }
}

/// The shell memo (spec §11) — counting only, and the whole reason it exists is
/// that a trip can otherwise close "settled" having lost every crate.
class _ShellMemoCard extends StatelessWidget {
  final VanTripPosition position;

  const _ShellMemoCard({required this.position});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final short = position.shellsDifference;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Empty crates',
            style: t.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: context.getRSize(10)),
          Text(
            'Loaded with ${position.shellsOut} '
            '${position.shellsOut == 1 ? 'crate' : 'crates'}, '
            '${position.shellsBack} empties came back.',
            style: t.textTheme.bodyMedium,
          ),
          if (position.hasShellLoss) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              'Lost crates: ${position.shellsLostUnits}'
              '${position.shellsLostValueKobo > 0 ? ' (${formatCurrency(position.shellsLostValueKobo / 100)})' : ''}. '
              'Shown only — not charged to the driver and not in any total '
              'above.',
              key: const ValueKey('reconcile-lost-crates'),
              style: t.textTheme.bodySmall?.copyWith(color: semantic.warning),
            ),
          ] else if (short > 0) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              '$short not returned as empties. Unsold full crates that came '
              'back are not lost.',
              style: t.textTheme.bodySmall?.copyWith(color: t.hintColor),
            ),
          ],
        ],
      ),
    );
  }
}

/// The uncosted disclosure (spec §9.1 #2).
///
/// Loading goods the warehouse had no costed batch for is allowed — but those
/// units contribute nothing to COGS, so the profit this screen is about to
/// persist is overstated by whatever they really cost. The dispatch screen
/// warns at load time; that warning is long gone by the time anyone closes the
/// trip, which is the moment the number actually gets believed. So it is
/// repeated here, next to the figure it undermines.
///
/// Deliberately no naira amount: the whole point is that the cost is *unknown*.
/// Naming a figure would be inventing one.
class _UncostedCard extends StatelessWidget {
  final VanTripPosition position;
  final Lexicon lex;

  const _UncostedCard({required this.position, required this.lex});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final n = position.uncostedUnits;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Profit is understated',
            style: t.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: context.getRSize(10)),
          Text(
            '$n ${n == 1 ? 'unit' : 'units'} on this trip left the store with '
            'no recorded cost, so nothing was counted against '
            "${n == 1 ? 'it' : 'them'} here.",
            style: t.textTheme.bodyMedium,
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            'Record what those ${lex.itemPluralLower} cost you, then this trip '
            'can be reconciled again on a true profit.',
            style: t.textTheme.bodySmall?.copyWith(color: semantic.warning),
          ),
        ],
      ),
    );
  }
}

/// What a closed trip says for itself — the artifact, read back.
class _ClosedCard extends StatelessWidget {
  final VanTripData trip;
  final String driverName;
  final Lexicon lex;

  const _ClosedCard({
    required this.trip,
    required this.driverName,
    required this.lex,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Trip closed',
            style: t.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: context.getRSize(12)),
          _Row(
            label: 'Value recovered',
            value: formatCurrency(trip.recoveredKobo / 100),
          ),
          _Row(
            label: 'Cost of the ${lex.itemPluralLower} gone',
            value: formatCurrency(trip.cogsKobo / 100),
          ),
          _Row(
            label: 'Profit booked',
            value: formatCurrency(trip.profitKobo / 100),
            strong: true,
          ),
          SizedBox(height: context.getRSize(10)),
          Text(
            trip.closedWithBalance
                ? 'This trip closed with a balance. Anything still owed sits on '
                      '$driverName\'s account and is settled on their next trip.'
                : 'This trip closed settled.',
            style: t.textTheme.bodySmall?.copyWith(color: t.hintColor),
          ),
          if (trip.restatedAt != null) ...[
            SizedBox(height: context.getRSize(8)),
            Text(
              trip.restatedReason ??
                  'This trip was corrected after it was closed.',
              style: t.textTheme.bodySmall?.copyWith(color: semantic.warning),
            ),
          ],
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;

  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => VanCard(child: child);
}

/// The bottom bar that holds the primary "Confirm & close trip".
class _PinnedClose extends StatelessWidget {
  final Widget child;

  const _PinnedClose({required this.child});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        context.getRSize(12) + context.deviceBottomPadding,
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: context.getRHeight(0.4),
        ),
        child: SingleChildScrollView(child: child),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;

  const _Row({required this.label, required this.value, this.strong = false});

  @override
  Widget build(BuildContext context) =>
      VanKvRow(label: label, value: value, strong: strong);
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
