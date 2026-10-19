import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_page_parts.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/pin_dialog.dart';

/// CEO-only "Delete Business & Account" confirmation (master plan §10.3 — the
/// Danger Zone). Irreversible. A prominent warning makes clear the action is
/// permanent and cannot be undone; the CEO confirms by re-entering their PIN —
/// the PIN is the confirmation gate. Online-only — the
/// [AuthService.deleteBusinessAndAccount] flow blocks when offline and only
/// wipes the device after the cloud confirms the hard delete.
class DeleteBusinessScreen extends ConsumerStatefulWidget {
  const DeleteBusinessScreen({super.key});

  @override
  ConsumerState<DeleteBusinessScreen> createState() =>
      _DeleteBusinessScreenState();
}

class _DeleteBusinessScreenState extends ConsumerState<DeleteBusinessScreen> {
  bool _deleting = false;

  Future<void> _confirmDelete(String businessId) async {
    // The confirmation gate: re-enter the CEO's PIN. PinDialog returns the
    // matching user.
    final approver = await PinDialog.show(
      context,
      title: 'Re-enter your PIN to delete',
    );
    if (approver == null || !mounted) return; // cancelled / wrong PIN

    // The PIN must belong to the CEO performing the deletion — on a shared
    // till another staff member's PIN must not authorise this.
    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null || approver.id != currentUser.id) {
      _showError('Re-enter your own PIN to confirm.');
      return;
    }

    setState(() => _deleting = true);
    try {
      await ref
          .read(authProvider)
          .deleteBusinessAndAccount(businessId: businessId);
      // On success the auth state is wiped and the app root reroutes to the
      // Welcome screen; this widget is torn down. Nothing more to do here.
    } on DeleteBusinessException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _showError(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _showError('Could not delete your business. Please try again.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    // Defense in depth (hard rule #6): the Danger Zone entry that opens this
    // screen is already gated on the same entry, but re-check at the screen
    // boundary.
    final canDelete = Gates.deleteBusiness.allows(ref);
    final business = ref.watch(currentBusinessProvider);

    if (!canDelete || business == null) {
      return const SettingsPageScaffold(
        icon: AppIcons.deleteForever,
        title: 'Delete Business',
        body: SettingsNoAccess(),
      );
    }

    return SettingsPageScaffold(
      icon: AppIcons.deleteForever,
      title: 'Delete Business',
      body: SettingsFadeIn(
        child: SettingsPageList(
          listKey: const Key('delete-business-list'),
          children: [
            // ── Warning banner ──────────────────────────────────────────
            Container(
              key: const Key('delete-business-warning'),
              padding: EdgeInsets.all(context.getRSize(16)),
              decoration: BoxDecoration(
                color: f.dangerTint,
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
                border: Border.all(color: f.dangerOutline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppIcon(
                        AppIcons.warning,
                        filled: true,
                        color: f.danger,
                        size: context.getRSize(24),
                      ),
                      SizedBox(width: context.getRSize(10)),
                      Expanded(
                        child: Text(
                          'This is permanent and cannot be undone',
                          style: context
                              .boldStyle(16)
                              .copyWith(color: f.danger),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(12)),
                  Text(
                    'You are about to permanently delete "${business.name}".\n\n'
                    'All sales, stock, customers, staff access, and money '
                    'records for this business will be permanently deleted and '
                    'cannot be recovered.\n\n'
                    'Your owner account will be deleted and this device will be '
                    'signed out. Any staff who belong to this business will lose '
                    'access to it.',
                    style: context
                        .regularStyle(14)
                        .copyWith(height: 1.45, color: t.colorScheme.onSurface),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.getRSize(28)),

            // ── Delete (opens the PIN confirmation gate) ────────────────
            AppButton(
              text: 'Delete Business',
              variant: AppButtonVariant.danger,
              icon: AppIcons.deleteForever,
              isLoading: _deleting,
              onPressed: _deleting ? null : () => _confirmDelete(business.id),
            ),
            SizedBox(height: context.getRSize(12)),
            Center(
              child: Text(
                'You will be asked for your PIN to confirm.',
                style: context.regularStyle(12).copyWith(color: muted),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
