/// Bottom-sheet shown when the admin taps a pending invite row in the
/// staff list. Replaces the old long-press / ellipsis flow with a single
/// rich modal: invitee + role + warehouse summary, the 8-character code
/// (so the admin can copy / share without re-issuing), and the two admin
/// actions (Regenerate / Revoke).
///
/// Pure widget — receives the invite row, the warehouse list (for name
/// resolution), the business name (for the share-message template), and
/// the two admin-action callbacks. The hosting screen owns the actual
/// API calls and confirm dialogs.
library;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/invite/widgets/code_share_card.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_constants.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/role_guard.dart';

class InvitePendingSheet extends StatelessWidget {
  final InviteData invite;
  final List<WarehouseData> warehouses;
  final String businessName;
  final VoidCallback onRegenerate;
  final VoidCallback onRevoke;

  const InvitePendingSheet({
    super.key,
    required this.invite,
    required this.warehouses,
    required this.businessName,
    required this.onRegenerate,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final subtleColor = textColor.withValues(alpha: 0.6);

    final inviteeName = invite.inviteeName.trim();
    final recipientName =
        (inviteeName.isNotEmpty && inviteeName != 'Unknown')
            ? inviteeName
            : null;
    final roleInfo = roleFor(invite.role);
    final warehouseName = warehouses
            .where((w) => w.id == invite.warehouseId)
            .firstOrNull
            ?.name ??
        'Unassigned';
    final daysRemaining = invite.expiresAt.difference(DateTime.now()).inDays;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: textColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              'Invitation Pending',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              recipientName != null
                  ? 'For $recipientName'
                  : 'Awaiting redemption',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: subtleColor),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _SummaryChip(text: roleInfo.label, color: roleInfo.color),
                _SummaryChip(text: warehouseName, color: subtleColor),
              ],
            ),
            const SizedBox(height: 20),
            InviteCodeBlock(
              humanCode: invite.code,
              businessName: businessName,
              recipientName: recipientName,
              email: invite.email,
              ttlDays: daysRemaining,
            ),
            const SizedBox(height: 16),
            Divider(color: subtleColor.withValues(alpha: 0.2), height: 1),
            const SizedBox(height: 16),
            RoleGuard(
              minTier: 5,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppButton(
                    text: 'Regenerate code',
                    variant: AppButtonVariant.secondary,
                    onPressed: onRegenerate,
                  ),
                  const SizedBox(height: 8),
                  AppButton(
                    text: 'Revoke invite',
                    variant: AppButtonVariant.danger,
                    onPressed: onRevoke,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            AppButton(
              text: 'Close',
              variant: AppButtonVariant.ghost,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String text;
  final Color color;

  const _SummaryChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
