import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/stores/widgets/add_location_flow.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_payments_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/record_driver_payment_sheet.dart';
import 'package:reebaplus_pos/features/van_sales/screens/drivers_list_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/load_van_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_reconcile_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_return_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/trip_balance_lines.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_ui.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// The Van Sales hub (#141, PRD #139 / ADR 0019) — the manager's way in to the
/// van side of the business.
///
/// **Why the hub has its own van list.** #140 made a van selectable only for a
/// `van.sell` driver explicitly assigned to it, precisely so a warehouse
/// cashier can never see or sell van stock. That means a manager loading a van
/// would find it in no store picker at all — so the hub reads [vansProvider]
/// (`onlyVans`) directly. A manager never *stands on* a van; they dispatch one.
///
/// Gated on `van.manage` (CEO + Manager). A driver holds `van.sell`, never
/// this, which is what makes "a driver records their own payment" impossible by
/// construction (spec §9.5 #21) rather than merely unreachable.
class VanSalesHubScreen extends ConsumerWidget {
  const VanSalesHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vans = ref.watch(vansProvider);
    final openTrips =
        ref.watch(openVanTripsProvider).valueOrNull ?? const <VanTripData>[];
    final driversById = {
      for (final d
          in ref.watch(vanDriverRowsProvider).valueOrNull ??
              const <VanDriverData>[])
        d.id: d,
    };
    // #748: who answers for a trip. A trip with no driver says so plainly.
    String nameOf(VanTripData t) => t.vanDriverId == null
        ? 'No driver assigned'
        : driversById[t.vanDriverId]?.name ?? 'Driver';

    // Open trip by van id — at most one each, guaranteed by the DAO block and
    // the cloud's partial-unique index.
    final tripByVan = <String, VanTripData>{
      for (final t in openTrips) t.vanStoreId: t,
    };

    // Body-guard (layer 2, hard rule #6): the drawer already hides the entry,
    // but a live revocation while the screen is open must empty it too.
    if (!Gates.vanManage.allows(ref)) {
      return const GlassyScaffold(
        title: 'Van Sales',
        body: _EmptyState(
          icon: AppIcons.lock,
          title: 'No access',
          message: 'You no longer have access to Van Sales.',
        ),
      );
    }

    return GlassyScaffold(
      title: 'Van Sales',
      subtitle: vans.isEmpty
          ? null
          : '${vans.length} ${vans.length == 1 ? 'van' : 'vans'} • '
                '${openTrips.length} out',
      // #779: a van is created right here (same flow as Settings → Stores).
      actions: const [_AddVanButton(iconOnly: true)],
      body: vans.isEmpty
          ? const _EmptyState(
              icon: AppIcons.supplier,
              title: 'No vans yet',
              message:
                  'Add your first van, then load it for a driver from here.',
              action: _AddVanButton(),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final columns = cardGridColumns(width, itemCount: vans.length);
                final gutter = contentGutter(
                  context,
                  width,
                  maxWidth: columns == 1
                      ? kContentMaxWidth
                      : cardGridMaxWidth(columns, gap: context.getRSize(12)),
                );
                final padding = EdgeInsets.fromLTRB(
                  gutter,
                  context.getRSize(20),
                  gutter,
                  context.getRSize(20) + context.deviceBottomPadding,
                );

                Widget driversLink() {
                  return _DriversLink(
                    driverCount: ref.watch(vanDriverEntriesProvider).length,
                    owingCount:
                        ref
                            .watch(vanDriverEntriesProvider)
                            .where((d) => d.owes)
                            .length +
                        ref.watch(noDriverGroupsProvider).length,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const DriversListScreen(),
                      ),
                    ),
                  );
                }

                Widget vanCard(int i) {
                  final van = vans[i];
                  final trip = tripByVan[van.id];
                  return _VanCard(
                    van: van,
                    trip: trip,
                    driverName: trip == null ? null : nameOf(trip),
                    onLoad: trip != null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => LoadVanScreen(vanStoreId: van.id),
                            ),
                          ),
                    onRecordPayment: trip == null
                        ? null
                        : () => RecordDriverPaymentSheet.show(
                            context,
                            trip: trip,
                            driverName: nameOf(trip),
                          ),
                    onPayments: trip == null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DriverPaymentsScreen(
                                tripId: trip.id,
                                driverName: nameOf(trip),
                                vanName: van.name,
                              ),
                            ),
                          ),
                    // #143 — the two mid-run events. Both only exist while the
                    // van is out: a restock loads onto an OPEN trip, and there is
                    // nothing to return against a van at the yard.
                    onRestock: trip == null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  LoadVanScreen(vanStoreId: van.id, trip: trip),
                            ),
                          ),
                    onReturn: trip == null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => VanReturnScreen(
                                trip: trip,
                                driverName: nameOf(trip),
                                vanName: van.name,
                              ),
                            ),
                          ),
                    // #145 — the way in to reconcile and close.
                    onReconcile: trip == null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => VanReconcileScreen(
                                tripId: trip.id,
                                driverName: nameOf(trip),
                                vanName: van.name,
                              ),
                            ),
                          ),
                  );
                }

                // +1 for the Drivers link, which sits above the vans: the
                // hub's axis is the fleet, but the money's axis is the PERSON
                // (spec §9.4 #14), so the way to a driver's account cannot
                // live behind a van card that may not even be out.
                if (columns == 1) {
                  return ListView.separated(
                    padding: padding,
                    itemCount: vans.length + 1,
                    separatorBuilder: (_, _) =>
                        SizedBox(height: context.getRSize(12)),
                    itemBuilder: (context, index) =>
                        index == 0 ? driversLink() : vanCard(index - 1),
                  );
                }

                // Wide: van cards in rows of [columns]; the Drivers link is one
                // column wide, at the start. Short last row is padded with
                // empty Expandeds so every card keeps the same width.
                final rowCount = (vans.length / columns).ceil();
                final gap = context.getRSize(12);
                return ListView.separated(
                  padding: padding,
                  itemCount: rowCount + 1,
                  separatorBuilder: (_, _) => SizedBox(height: gap),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Row(
                        children: [
                          Expanded(child: driversLink()),
                          for (var c = 1; c < columns; c++) ...[
                            SizedBox(width: gap),
                            const Expanded(child: SizedBox.shrink()),
                          ],
                        ],
                      );
                    }
                    final start = (index - 1) * columns;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var c = 0; c < columns; c++) ...[
                          if (c > 0) SizedBox(width: gap),
                          Expanded(
                            child: start + c < vans.length
                                ? vanCard(start + c)
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    );
                  },
                );
              },
            ),
    );
  }
}

/// The way in to the Drivers list (#146) — who owes what, across every trip.
class _DriversLink extends StatelessWidget {
  final int driverCount;
  final int owingCount;
  final VoidCallback onTap;

  const _DriversLink({
    required this.driverCount,
    required this.owingCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: AppDecorations.card(context, radius: 16),
        child: Row(
          children: [
            Container(
              width: context.getRSize(40),
              height: context.getRSize(40),
              decoration: BoxDecoration(
                color: t.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                AppIcons.managerRole,
                color: t.colorScheme.primary,
                size: context.getRSize(16),
              ),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Drivers',
                    style: t.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    driverCount == 0
                        ? 'Balances, trips and full money history'
                        : '$driverCount '
                              '${driverCount == 1 ? 'driver' : 'drivers'}'
                              '${owingCount == 0 ? ' • all settled' : ' • $owingCount owing'}',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: owingCount > 0 ? semantic.warning : subtext,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              AppIcons.chevronRight,
              size: context.getRSize(13),
              color: subtext,
            ),
          ],
        ),
      ),
    );
  }
}

/// One van's row: its name, whether it is out, and the way in to Load Van.
class _VanCard extends StatelessWidget {
  final StoreData van;
  final VanTripData? trip;
  final String? driverName;
  final VoidCallback? onLoad;

  /// Opens the trip's money story — the driver's balance, the trip's ledger
  /// history, and the way to record a payment (#144). Null when the van is
  /// home: there is no trip to remit against.
  final VoidCallback? onPayments;

  /// Opens the Record Payment form for this van's open trip (#790).
  final VoidCallback? onRecordPayment;

  /// Loads MORE onto the open trip (#143). Null when the van is home — a
  /// restock needs a trip to restock onto; loading a parked van opens one.
  final VoidCallback? onRestock;

  /// Records goods coming back off the open trip (#143). Null when the van is
  /// home.
  final VoidCallback? onReturn;

  /// Opens Reconcile & close (#145) — the trip's whole position and the way to
  /// end the run. Null when the van is home: there is nothing to reconcile.
  final VoidCallback? onReconcile;

  const _VanCard({
    required this.van,
    required this.trip,
    required this.driverName,
    required this.onLoad,
    required this.onPayments,
    required this.onRecordPayment,
    required this.onRestock,
    required this.onReturn,
    required this.onReconcile,
  });

  /// True when this trip has been out longer than the nag window (spec §9.4
  /// #17). Revenue is recognised while a trip lingers and its cost is not
  /// booked until close, so a forgotten trip quietly separates the two.
  bool get _isStale =>
      trip != null &&
      DateTime.now().difference(trip!.openedAt).inDays >= kVanStaleTripDays;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final isOut = trip != null;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    return VanCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.supplier,
                size: context.getRSize(18),
                color: isOut ? semantic.warning : subtext,
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: Text(
                  van.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(width: context.getRSize(8)),
              _StatusChip(isOut: isOut),
            ],
          ),
          if (isOut) ...[
            SizedBox(height: context.getRSize(6)),
            // Driver and "out since" as one quiet line.
            Text(
              '${driverName ?? 'Driver'} \u00b7 Out since '
              '${_formatDate(trip!.openedAt)}',
              style: t.textTheme.bodySmall?.copyWith(color: subtext),
            ),
            SizedBox(height: context.getRSize(12)),
            // #800: the same balance split three ways, so nobody adds it up
            // by hand when the driver hands money in.
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(14),
                vertical: context.getRSize(10),
              ),
              decoration: BoxDecoration(
                color: t.colorScheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
              ),
              child: TripBalanceLines(tripId: trip!.id),
            ),
            SizedBox(height: context.getRSize(12)),
            // #143 / #144 / #790: the four things a manager reaches for while
            // the van is out, as equal tonal tiles.
            Row(
              children: [
                Expanded(
                  child: VanTonalTile(
                    label: 'Restock',
                    icon: AppIcons.stockAdjustment,
                    onPressed: onRestock,
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: VanTonalTile(
                    label: 'Returns',
                    icon: AppIcons.undo,
                    onPressed: onReturn,
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: VanTonalTile(
                    key: Key('van-record-payment-${van.id}'),
                    label: 'Record payment',
                    icon: AppIcons.transfer,
                    onPressed: onRecordPayment,
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: VanTonalTile(
                    label: 'Payments',
                    icon: AppIcons.history,
                    onPressed: onPayments,
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(12)),
            // #145 — the end of the run. The one primary action.
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onReconcile,
                icon: Icon(AppIcons.goal, size: context.getRSize(14)),
                label: const Text('Reconcile & close'),
              ),
            ),
            if (_isStale) ...[
              SizedBox(height: context.getRSize(10)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    AppIcons.warning,
                    size: context.getRSize(12),
                    color: semantic.warning,
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Expanded(
                    child: Text(
                      'Out for '
                      '${DateTime.now().difference(trip!.openedAt).inDays} days. '
                      'Sales on this trip are counted already, but the profit '
                      'is not booked until you close it.',
                      style: t.textTheme.bodySmall?.copyWith(
                        color: semantic.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ] else ...[
            SizedBox(height: context.getRSize(12)),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onLoad,
                icon: Icon(
                  AppIcons.stockAdjustment,
                  size: context.getRSize(14),
                ),
                label: const Text('Load Van'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _StatusChip extends StatelessWidget {
  final bool isOut;

  const _StatusChip({required this.isOut});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final color = isOut ? semantic.warning : semantic.success;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isOut ? 'On the road' : 'At the yard',
        style: t.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// "Add a van" — runs the shared [addLocationFlow] with the kind fixed to van.
/// The new van reaches the list through [vansProvider]'s stream. The busy flag
/// stops a double tap opening two sheets.
class _AddVanButton extends ConsumerStatefulWidget {
  final bool iconOnly;

  const _AddVanButton({this.iconOnly = false});

  @override
  ConsumerState<_AddVanButton> createState() => _AddVanButtonState();
}

class _AddVanButtonState extends ConsumerState<_AddVanButton> {
  bool _busy = false;

  Future<void> _add() async {
    if (_busy) return;
    _busy = true;
    try {
      await addLocationFlow(context, ref, isVan: true);
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Gates.vanManage.allows(ref)) return const SizedBox.shrink();
    if (widget.iconOnly) {
      return IconButton(
        tooltip: 'Add a van',
        icon: const Icon(AppIcons.add),
        onPressed: _add,
      );
    }
    return AppButton(
      text: 'Add a van',
      icon: AppIcons.add,
      variant: AppButtonVariant.outline,
      height: kMinInteractiveDimension,
      onAsyncPressed: _add,
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String message;
  final Widget? action;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(32)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: context.getRSize(40), color: subtext),
            SizedBox(height: context.getRSize(16)),
            Text(
              title,
              style: t.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.getRSize(8)),
            Text(
              message,
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(color: subtext),
            ),
            if (action != null) ...[
              SizedBox(height: context.getRSize(20)),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
