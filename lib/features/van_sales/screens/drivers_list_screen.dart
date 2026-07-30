import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/van_sales/driver_directory.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_profile_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// The Drivers list (#146, PRD #139 / ADR 0019, van-sales spec §9.5).
///
/// The customers/suppliers list, for people who carry stock instead of buying
/// it: each driver, what they currently owe, and the way through to their whole
/// money story.
///
/// **Why a removed driver can still be on this list.** Offboarding must not be
/// able to hide a debt (spec §9.5 #19). A former driver whose ledger balance is
/// not zero stays here, badged, until it is settled or deliberately written
/// off. The rule lives in the pure [buildDriversList]; this screen only renders
/// it. Its other half is the guard on the removal path itself
/// (`VanTripsDao.assertDriverOffboardable`, spec §9.5 #20) — together they mean
/// a driver's debt cannot be made to disappear from either end.
///
/// Gated `van.manage`, like the rest of the hub: a driver holds `van.sell` and
/// never reaches this, which is what makes "a driver settles their own account"
/// impossible by construction rather than merely unreachable (spec §9.5 #21).
class DriversListScreen extends ConsumerWidget {
  const DriversListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Guarded.screen(
      gate: Gates.vanManage,
      builder: (context) => const _DriversListBody(),
      denied: GlassyScaffold(
        title: 'Drivers',
        body: _Empty(
          icon: FontAwesomeIcons.lock.data,
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
    final owing = drivers.where((d) => d.owes).length;

    return GlassyScaffold(
      title: 'Drivers',
      subtitle: drivers.isEmpty
          ? null
          : '${drivers.length} ${drivers.length == 1 ? 'driver' : 'drivers'}'
                '${owing == 0 ? '' : ' • $owing owing'}',
      body: AppRefreshWrapper(
        child: drivers.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(height: context.getRSize(100)),
                  _Empty(
                    icon: FontAwesomeIcons.userTie.data,
                    title: 'No drivers yet',
                    message:
                        'Invite a staff member with the Driver role, then load '
                        'a van for them from Van Sales.',
                  ),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(16),
                  context.getRSize(12),
                  context.getRSize(16),
                  context.getRSize(24) + context.deviceBottomPadding,
                ),
                itemCount: drivers.length,
                itemBuilder: (_, i) {
                  final entry = drivers[i];
                  return _DriverRow(
                    entry: entry,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            DriverProfileScreen(driverUserId: entry.userId),
                      ),
                    ),
                  );
                },
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
                FontAwesomeIcons.userTie.data,
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
                          entry.user.name,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: context.getRFontSize(16),
                            color: t.colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (entry.standing != DriverStanding.active) ...[
                        SizedBox(width: context.getRSize(8)),
                        DriverStandingBadge(standing: entry.standing),
                      ],
                    ],
                  ),
                  if ((entry.user.phone ?? '').isNotEmpty) ...[
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      entry.user.phone!,
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
            Icon(Icons.chevron_right, color: subtext, size: context.getRSize(20)),
          ],
        ),
      ),
    );
  }
}

/// The "Removed" / "Suspended" pill (#146, spec §9.5 #19).
///
/// Public because the profile header shows the same badge: a manager who opens
/// a former driver from the list must not lose the one fact that explains why
/// the screen has no actions on it.
class DriverStandingBadge extends StatelessWidget {
  final DriverStanding standing;

  const DriverStandingBadge({super.key, required this.standing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final (label, color) = switch (standing) {
      DriverStanding.active => ('Driver', semantic.success),
      DriverStanding.suspended => ('Suspended', semantic.warning),
      DriverStanding.removed => ('Removed', t.colorScheme.error),
    };
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
        label,
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
