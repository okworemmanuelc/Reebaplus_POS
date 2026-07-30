import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

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
///  6. **Confirm & close**, which warns first if this device still has road
///     sales in its outbox — you do not assign blame from an incomplete
///     picture.
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
      return GlassyScaffold(
        title: 'Reconcile & close',
        body: _Empty(
          icon: FontAwesomeIcons.lock.data,
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
    final tracksCrates = businessTracksCrates(ref.watch(currentBusinessProvider));
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

    return GlassyScaffold(
      title: 'Reconcile & close',
      subtitle: '$driverName • $vanName',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20) + context.deviceBottomPadding,
        ),
        children: [
          _OutstandingCard(position: position, lex: lex),
          SizedBox(height: context.getRSize(16)),
          _MovementCard(position: position, lex: lex),
          if (position.shortages.isNotEmpty) ...[
            SizedBox(height: context.getRSize(16)),
            _ShortageCard(
              position: position,
              productName: productName,
              lex: lex,
            ),
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
          if (isOpen) ...[
            _actions(context, ref, trip, position),
            SizedBox(height: context.getRSize(20)),
            if (pendingSales > 0)
              _PendingSalesWarning(count: pendingSales, lex: lex),
            if (pendingSales > 0) SizedBox(height: context.getRSize(12)),
            Guarded(
              gate: Gates.vanManage,
              builder: (context, allow) => SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: allow(
                    () => _confirmAndClose(
                      context,
                      ref,
                      trip: trip,
                      position: position,
                      pendingSales: pendingSales,
                    ),
                  ),
                  icon: Icon(
                    FontAwesomeIcons.flagCheckered.data,
                    size: context.getRSize(14),
                  ),
                  label: const Text('Confirm & close trip'),
                ),
              ),
            ),
          ] else
            _ClosedCard(trip: trip, driverName: driverName, lex: lex),
        ],
      ),
    );
  }

  Widget _actions(
    BuildContext context,
    WidgetRef ref,
    VanTripData trip,
    VanTripPosition position,
  ) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
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
                icon: Icon(
                  FontAwesomeIcons.arrowRotateLeft.data,
                  size: context.getRSize(14),
                ),
                label: const Text('Final return'),
              ),
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => RecordDriverPaymentSheet.show(
                  context,
                  trip: trip,
                  driverName: driverName,
                ),
                icon: Icon(
                  FontAwesomeIcons.moneyBillTransfer.data,
                  size: context.getRSize(14),
                ),
                label: const Text('Final payment'),
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
              child: OutlinedButton.icon(
                onPressed: position.shortageOwedKobo <= 0
                    ? null
                    : () => VanWriteOffSheet.show(
                        context,
                        trip: trip,
                        driverName: driverName,
                        type: kDriverLedgerTypeShortageWriteoff,
                        owedKobo: position.shortageOwedKobo,
                      ),
                icon: Icon(
                  FontAwesomeIcons.magnifyingGlassMinus.data,
                  size: context.getRSize(14),
                ),
                label: const Text('Write off shortage'),
              ),
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: position.damageOwedKobo <= 0
                    ? null
                    : () => VanWriteOffSheet.show(
                        context,
                        trip: trip,
                        driverName: driverName,
                        type: kDriverLedgerTypeDamageWriteoff,
                        owedKobo: position.damageOwedKobo,
                      ),
                icon: Icon(
                  FontAwesomeIcons.wineGlassEmpty.data,
                  size: context.getRSize(14),
                ),
                label: const Text('Write off damage'),
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
    final tracksCrates = businessTracksCrates(ref.read(currentBusinessProvider));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Close this trip?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tracksCrates) ...[
              Text(
                'Loaded with ${position.shellsOut} '
                '${position.shellsOut == 1 ? 'shell' : 'shells'}, '
                '${position.shellsBack} came back.',
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
            if (pendingSales > 0) ...[
              SizedBox(height: context.getRSize(10)),
              Text(
                'This device still has $pendingSales road '
                '${pendingSales == 1 ? 'sale' : 'sales'} waiting to sync. Until '
                'they go up, those ${lex.itemPluralLower} count as missing and '
                'the driver looks liable for them.',
                style: t.textTheme.bodyMedium?.copyWith(
                  color: semantic.warning,
                ),
              ),
            ],
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
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Close trip'),
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
      accent: color,
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
      accent: t.colorScheme.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The run, at load price',
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
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
          _Row(
            label: 'Unaccounted for (${position.shortageUnits})',
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
    final semantic = t.extension<AppSemanticColors>()!;
    return _Card(
      accent: semantic.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${lex.itemPlural} that never came back',
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
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
      accent: short > 0 ? semantic.warning : semantic.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Empty crates',
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: context.getRSize(10)),
          Text(
            'Loaded with ${position.shellsOut} '
            '${position.shellsOut == 1 ? 'shell' : 'shells'}, '
            '${position.shellsBack} came back.',
            style: t.textTheme.bodyMedium,
          ),
          if (short > 0) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              '$short not returned. Counted only for now — no deposit money is '
              'moved.',
              style: t.textTheme.bodySmall?.copyWith(color: semantic.warning),
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
      accent: semantic.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Profit is understated',
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
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

/// The close-vs-outbox barrier, shown before the button rather than only in the
/// dialog — a manager should see the caveat while they are still reading the
/// figures it affects.
class _PendingSalesWarning extends StatelessWidget {
  final int count;
  final Lexicon lex;

  const _PendingSalesWarning({required this.count, required this.lex});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: semantic.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(context.getRSize(12)),
        border: Border.all(color: semantic.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            FontAwesomeIcons.cloudArrowUp.data,
            size: context.getRSize(16),
            color: semantic.warning,
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Text(
              '$count road ${count == 1 ? 'sale is' : 'sales are'} still '
              'waiting to sync from this device. Until they go up those '
              '${lex.itemPluralLower} count as missing.',
              style: t.textTheme.bodySmall?.copyWith(
                color: t.colorScheme.onSurface,
              ),
            ),
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
      accent: semantic.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Trip closed',
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
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
  final Color accent;
  final Widget child;

  const _Card({required this.accent, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.getRSize(16)),
        border: Border.all(color: t.dividerColor),
      ),
      child: child,
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;

  const _Row({required this.label, required this.value, this.strong = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: t.textTheme.bodySmall?.copyWith(
                color: strong ? t.colorScheme.onSurface : subtext,
                fontWeight: strong ? FontWeight.w700 : null,
              ),
            ),
          ),
          SizedBox(width: context.getRSize(10)),
          Text(
            value,
            style: t.textTheme.bodyMedium?.copyWith(
              fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
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
