import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/industry/lexicon.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The close-vs-outbox barrier (#208 item 5, van-sales spec §7.4).
///
/// Spec §7.4 says close "warns (or blocks Confirm)". v1 shipped the warning
/// half; this is the stricter reading, and the shape of it is the whole point:
///
///  * **The primary is disabled while road sales sit unsynced.** A manager
///    settling a trip is deciding who owes what, and an un-pushed sale reads as
///    a shortage — the driver looks liable for goods they sold and were paid
///    for. That is not a caveat to skim past on the way to the happy path, so
///    the happy path is closed.
///  * **The override is always there.** Sync can be down for days (a device
///    DNS/VPN failure surfaces as errno 7 and nothing in the app can fix it),
///    and a trip that cannot be closed is worse than a trip closed early: the
///    van cannot go out again, the driver's balance never rolls forward, and a
///    late sale would have posted its own correction anyway (spec §9.4 #15). So
///    "Close anyway" sits below the disabled primary, deliberately quieter, and
///    routes through the ordinary close confirmation — which names the risk in
///    the manager's own words before it writes anything.
///
/// **The honest limit (#145).** Everything here is scoped to *this device*. A
/// device can read only its own `sync_queue`; the driver's un-pushed envelopes
/// are on the driver's phone, and `public.devices` is cloud-only analytics that
/// never syncs down. So every string says "this device" and none of them claims
/// the trip is complete — a clean barrier here means nothing is stuck *here*,
/// not that nothing is stuck anywhere.
///
/// Gated `Gates.vanManage` at fire time like every other write on the screen;
/// when the gate denies, both controls disappear (hide, don't disable — hard
/// rule #7). The disabled primary below is a *data* state, not a permission
/// one, which is why the two do not conflict.
class VanCloseBarrier extends StatelessWidget {
  /// Road sales for this trip still sitting in **this device's** outbox.
  final int pendingSales;

  /// The trade's own word for a sellable item (ADR 0015).
  final Lexicon lex;

  /// Opens the ordinary close confirmation. The barrier decides *how* close may
  /// be reached, never what closing means — that stays with the screen.
  final VoidCallback onClose;

  const VanCloseBarrier({
    super.key,
    required this.pendingSales,
    required this.lex,
    required this.onClose,
  });

  /// True while the outbox holds road sales for this trip — the primary path is
  /// closed and only the explicit override remains.
  bool get isBlocked => pendingSales > 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isBlocked) ...[
          _PendingSalesWarning(count: pendingSales, lex: lex),
          SizedBox(height: context.getRSize(12)),
        ],
        Guarded(
          gate: Gates.vanManage,
          builder: (context, allow) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                // Disabled by the outbox, not by permission. `allow` still
                // wraps the live callback so a revocation between frame and tap
                // is caught (ADR 0002 layer 3).
                onPressed: isBlocked ? null : allow(onClose),
                icon: Icon(
                  FontAwesomeIcons.flagCheckered.data,
                  size: context.getRSize(14),
                ),
                label: const Text('Confirm & close trip'),
              ),
              if (isBlocked) ...[
                SizedBox(height: context.getRSize(6)),
                TextButton(
                  onPressed: allow(onClose),
                  child: const Text('Close anyway'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The outbox caveat, shown above the button rather than only in the dialog — a
/// manager should read it while they are still looking at the figures it
/// undermines, not after they have decided.
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
              '${lex.itemPluralLower} count as missing, so closing now would '
              'settle on an incomplete picture.',
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
