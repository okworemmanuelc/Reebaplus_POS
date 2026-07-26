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
import 'package:reebaplus_pos/features/van_sales/screens/load_van_screen.dart';
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
    final balances =
        ref.watch(driverBalancesProvider).valueOrNull ?? const <String, int>{};
    final users = ref.watch(usersByBusinessProvider).valueOrNull ??
        const <String, UserData>{};

    // Open trip by van id — at most one each, guaranteed by the DAO block and
    // the cloud's partial-unique index.
    final tripByVan = <String, VanTripData>{
      for (final t in openTrips) t.vanStoreId: t,
    };

    // Body-guard (layer 2, hard rule #6): the drawer already hides the entry,
    // but a live revocation while the screen is open must empty it too.
    if (!Gates.vanManage.allows(ref)) {
      return GlassyScaffold(
        title: 'Van Sales',
        body: _EmptyState(
          icon: FontAwesomeIcons.lock.data,
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
      body: vans.isEmpty
          ? _EmptyState(
              icon: FontAwesomeIcons.truck.data,
              title: 'No vans yet',
              message:
                  'Add a van in Settings → Stores, then load it for a driver '
                  'from here.',
            )
          : ListView.separated(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(20),
                context.getRSize(20),
                context.getRSize(20),
                context.getRSize(20) + context.deviceBottomPadding,
              ),
              itemCount: vans.length,
              separatorBuilder: (_, _) =>
                  SizedBox(height: context.getRSize(12)),
              itemBuilder: (context, i) {
                final van = vans[i];
                final trip = tripByVan[van.id];
                return _VanCard(
                  van: van,
                  trip: trip,
                  driverName: trip == null
                      ? null
                      : users[trip.driverUserId]?.name ?? 'Driver',
                  driverBalanceKobo:
                      trip == null ? null : balances[trip.driverUserId] ?? 0,
                  onLoad: trip != null
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => LoadVanScreen(vanStoreId: van.id),
                            ),
                          ),
                );
              },
            ),
    );
  }
}

/// One van's row: its name, whether it is out, and the way in to Load Van.
class _VanCard extends StatelessWidget {
  final StoreData van;
  final VanTripData? trip;
  final String? driverName;
  final int? driverBalanceKobo;
  final VoidCallback? onLoad;

  const _VanCard({
    required this.van,
    required this.trip,
    required this.driverName,
    required this.driverBalanceKobo,
    required this.onLoad,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final isOut = trip != null;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FontAwesomeIcons.truck.data,
                size: context.getRSize(16),
                color: isOut ? semantic.warning : subtext,
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: Text(
                  van.name,
                  style: t.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _StatusChip(isOut: isOut),
            ],
          ),
          SizedBox(height: context.getRSize(12)),
          if (isOut) ...[
            _DetailRow(
              icon: FontAwesomeIcons.userTie.data,
              label: driverName ?? 'Driver',
            ),
            SizedBox(height: context.getRSize(6)),
            _DetailRow(
              icon: FontAwesomeIcons.calendarDay.data,
              label: 'Out since ${_formatDate(trip!.openedAt)}',
            ),
            SizedBox(height: context.getRSize(6)),
            // Negative = the driver owes. Shown as a plain "owes ₦X" rather
            // than a signed figure — a shop owner reads a debt, not a sign.
            _DetailRow(
              icon: FontAwesomeIcons.scaleBalanced.data,
              label: (driverBalanceKobo ?? 0) < 0
                  ? 'Owes ${formatCurrency(-(driverBalanceKobo ?? 0) / 100)}'
                  : (driverBalanceKobo ?? 0) == 0
                      ? 'Settled'
                      : 'In credit '
                          '${formatCurrency((driverBalanceKobo ?? 0) / 100)}',
              color: (driverBalanceKobo ?? 0) < 0 ? t.colorScheme.error : null,
            ),
            SizedBox(height: context.getRSize(12)),
            Text(
              // The one honest thing to say in this slice: reconcile-and-close
              // is #145. Promising a button that isn't there would be worse.
              'Reconcile and close arrives with the trip-close step.',
              style: t.textTheme.bodySmall?.copyWith(color: subtext),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onLoad,
                icon: Icon(
                  FontAwesomeIcons.boxesPacking.data,
                  size: context.getRSize(14),
                ),
                label: const Text('Load Van'),
              ),
            ),
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

class _DetailRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color? color;

  const _DetailRow({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Row(
      children: [
        Icon(icon, size: context.getRSize(12), color: color ?? subtext),
        SizedBox(width: context.getRSize(8)),
        Expanded(
          child: Text(
            label,
            style: t.textTheme.bodySmall?.copyWith(color: color ?? subtext),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String message;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
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
          ],
        ),
      ),
    );
  }
}
