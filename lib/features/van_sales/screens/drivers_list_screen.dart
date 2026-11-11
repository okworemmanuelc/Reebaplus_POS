import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/van_sales/driver_directory.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_profile_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_driver_pickers.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// The Drivers list (#146, reworked by #748; PRD #139 / ADR 0019, spec §9.5).
///
/// Each driver, what they currently owe, and the way through to their whole
/// money story. A driver is just a name (and optional phone): no invite, no
/// sign-in. Debt is the DRIVER's, across every trip and every van — a new driver
/// never inherits the last driver's debt.
///
/// **A removed driver can still be on this list** while they owe (spec §9.5 #19):
/// removing someone from the pick lists must not hide a debt. The rule lives in
/// the pure [buildDriversList]. Trips that were loaded with no driver and still
/// owe appear under "No driver assigned", one row per van.
///
/// Gated `van.manage`, like the rest of the hub.
class DriversListScreen extends ConsumerWidget {
  const DriversListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Guarded.screen(
      gate: Gates.vanManage,
      builder: (context) => const _DriversListBody(),
      denied: const GlassyScaffold(
        title: 'Drivers',
        body: _Empty(
          icon: AppIcons.lock,
          title: 'No access',
          message: 'You no longer have access to Van Sales.',
        ),
      ),
    );
  }
}

class _DriversListBody extends ConsumerWidget {
  const _DriversListBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(vanDriverEntriesProvider);
    final noDriver = ref.watch(noDriverGroupsProvider);
    final vanNames = {
      for (final v in ref.watch(vansProvider)) v.id: v.name,
    };
    final owing = drivers.where((d) => d.owes).length + noDriver.length;
    final isEmpty = drivers.isEmpty && noDriver.isEmpty;

    return GlassyScaffold(
      title: 'Drivers',
      subtitle: drivers.isEmpty
          ? null
          : '${drivers.length} ${drivers.length == 1 ? 'driver' : 'drivers'}'
                '${owing == 0 ? '' : ' • $owing owing'}',
      actions: [
        IconButton(
          tooltip: 'Add a driver',
          icon: const Icon(AppIcons.userAdd),
          onPressed: () => showAddVanDriverDialog(context, ref),
        ),
      ],
      body: AppRefreshWrapper(
        child: isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(height: context.getRSize(100)),
                  const _Empty(
                    icon: AppIcons.managerRole,
                    title: 'No drivers yet',
                    message:
                        'Tap the add button to put in a driver\'s name. A van '
                        'can also go out with no driver at all.',
                  ),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(16),
                  context.getRSize(12),
                  context.getRSize(16),
                  context.getRSize(24) + context.deviceBottomPadding,
                ),
                children: [
                  for (final entry in drivers)
                    _DriverRow(
                      entry: entry,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              DriverProfileScreen(vanDriverId: entry.driverId),
                        ),
                      ),
                    ),
                  for (final g in noDriver)
                    _NoDriverRow(
                      vanName: vanNames[g.vanStoreId] ?? 'Van',
                      balanceKobo: g.balanceKobo,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DriverProfileScreen(
                            noDriverVanStoreId: g.vanStoreId,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// A van's "No driver assigned" group: what its driverless trips owe.
class _NoDriverRow extends StatelessWidget {
  final String vanName;
  final int balanceKobo;
  final VoidCallback onTap;

  const _NoDriverRow({
    required this.vanName,
    required this.balanceKobo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: context.getRSize(12)),
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: t.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.dividerColor),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No driver assigned',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(16),
                      color: t.colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    vanName,
                    style: TextStyle(
                      color: subtext,
                      fontSize: context.getRFontSize(13),
                    ),
                  ),
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    balanceKobo < 0
                        ? 'Owes ${formatCurrency(-balanceKobo / 100)}'
                        : 'In credit ${formatCurrency(balanceKobo / 100)}',
                    style: TextStyle(
                      color: balanceKobo < 0
                          ? t.colorScheme.error
                          : subtext,
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              AppIcons.chevronRight,
              color: subtext,
              size: context.getRSize(20),
            ),
          ],
        ),
      ),
    );
  }
}

/// One driver's row: who they are, where they stand, and what they owe.
class _DriverRow extends StatelessWidget {
  final DriverListEntry entry;
  final VoidCallback onTap;

  const _DriverRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    // Negative = the driver owes. Shown as a plain "Owes ₦X" rather than a
    // signed figure — a shop owner reads a debt, not a sign.
    final balanceColor = entry.owes
        ? t.colorScheme.error
        : (entry.inCredit ? semantic.success : subtext);
    final balanceLabel = entry.owes
        ? 'Owes ${formatCurrency(-entry.balanceKobo / 100)}'
        : (entry.inCredit
              ? 'In credit ${formatCurrency(entry.balanceKobo / 100)}'
              : 'Settled');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: context.getRSize(12)),
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: t.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.dividerColor),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(48),
              height: context.getRSize(48),
              decoration: BoxDecoration(
                color: t.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                AppIcons.managerRole,
                color: t.colorScheme.primary,
                size: context.getRSize(20),
              ),
            ),
            SizedBox(width: context.getRSize(16)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.driver.name,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: context.getRFontSize(16),
                            color: t.colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (entry.isFormerDriver) ...[
                        SizedBox(width: context.getRSize(8)),
                        const RemovedDriverBadge(),
                      ],
                    ],
                  ),
                  if ((entry.driver.phone ?? '').isNotEmpty) ...[
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      entry.driver.phone!,
                      style: TextStyle(
                        color: subtext,
                        fontSize: context.getRFontSize(13),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    balanceLabel,
                    style: TextStyle(
                      color: balanceColor,
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Icon(AppIcons.chevronRight, color: subtext, size: context.getRSize(20)),
          ],
        ),
      ),
    );
  }
}

/// The "Removed" pill (#146, spec §9.5 #19). Public because the profile header
/// shows the same badge: a manager who opens a removed driver from the list must
/// not lose the one fact that explains why the screen has no actions on it.
class RemovedDriverBadge extends StatelessWidget {
  const RemovedDriverBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = t.colorScheme.error;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(3),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Removed',
        style: t.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
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
