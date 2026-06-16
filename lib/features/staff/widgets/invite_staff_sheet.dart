import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Invite-new-staff modal (master plan §9.4). Single form: email + role +
/// store → "Generate code". Role dropdown is filtered by the current user's
/// role (CEO sees all four; Manager sees only Cashier + Stock keeper). Store
/// dropdown is locked to the Manager's own store. After generating, the sheet
/// switches to show the code with Copy / SMS / WhatsApp share.
class InviteStaffSheet extends ConsumerStatefulWidget {
  const InviteStaffSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const InviteStaffSheet(),
    );
  }

  @override
  ConsumerState<InviteStaffSheet> createState() => _InviteStaffSheetState();
}

class _InviteStaffSheetState extends ConsumerState<InviteStaffSheet> {
  final _emailCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _roleId;
  String? _storeId;
  bool _generating = false;

  // Holds the generated code + invitee email once "Generate" succeeds; null
  // while the form is still showing.
  String? _generatedCode;
  String? _generatedEmail;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  /// Roles the current user may invite. CEO: all four. Manager: Cashier and
  /// Stock keeper only.
  List<RoleData> _invitableRoles(List<RoleData> all, String? mySlug) {
    if (mySlug == 'manager') {
      return all
          .where((r) => r.slug == 'cashier' || r.slug == 'stock_keeper')
          .toList();
    }
    return all;
  }

  String _randomCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random.secure();
    return List.generate(8, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Future<void> _generate() async {
    if (!_formKey.currentState!.validate()) return;
    // Write-boundary re-check (§10.2.1): the screen + drawer entry are gated on
    // `staff.invite`, but re-check the effective permission before writing the
    // invite so a revoked per-user override is honored at the action too.
    if (!ref.read(currentUserPermissionsProvider).contains('staff.invite')) {
      AppNotification.showError(
        context,
        'You don\'t have permission to do that.',
      );
      return;
    }
    if (_roleId == null || _storeId == null) {
      AppNotification.showError(context, 'Pick a role and a store.');
      return;
    }
    final email = _emailCtrl.text.trim().toLowerCase();

    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    final currentUser = auth.currentUser;
    final businessId = currentUser?.businessId;
    if (currentUser == null || businessId == null) {
      AppNotification.showError(context, 'No active session.');
      return;
    }

    // Duplicate guard: an email already belonging to an active staff member
    // of this business can't be invited again (master plan §9.4).
    final existing = await db.storesDao.getUserByEmail(
      email,
      preferredBusinessId: businessId,
    );
    if (existing != null) {
      final membership = await db.userBusinessesDao.getForUserInBusiness(
        existing.id,
        businessId,
      );
      if (membership != null && membership.status == 'active') {
        if (!mounted) return;
        AppNotification.showError(
          context,
          'This email is already a staff member.',
        );
        return;
      }
    }

    setState(() => _generating = true);
    try {
      // Resolved before any await so a mid-write dispose can't invalidate the
      // ref reads. Drives the §26.4 invite-generated notification below.
      final actorIsCeo = ref.read(currentUserRoleProvider)?.slug == 'ceo';
      final roles =
          ref.read(allRolesProvider).valueOrNull ?? const <RoleData>[];
      var invitedRoleName = 'staff';
      for (final r in roles) {
        if (r.id == _roleId) {
          invitedRoleName = r.name;
          break;
        }
      }
      final code = _randomCode();
      final companion = InviteCodesCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: businessId,
        roleId: _roleId!,
        code: code,
        email: email,
        storeId: _storeId!,
        generatedByUserId: currentUser.id,
        expiresAt: DateTime.now().add(const Duration(days: 7)),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await db.inviteCodesDao.insertInvite(companion);
      await db.activityLogDao.log(
        action: 'staff.invite',
        description: 'Generated invite code for $email',
        staffId: currentUser.id,
        storeId: _storeId,
      );
      // §26.4 Staff — "New staff invite generated (fires to CEO)". Fires only
      // when a non-CEO (a Manager) generated it; the CEO is never self-notified.
      if (!actorIsCeo) {
        final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs([
          'ceo',
        ]);
        for (final ceoId in ceoIds) {
          if (ceoId == currentUser.id) continue;
          await db.notificationsDao.fireNotification(
            type: 'staff.invited',
            message: '${currentUser.name} invited $email as $invitedRoleName',
            linkedRecordId: companion.id.value,
            recipientUserId: ceoId,
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _generatedCode = code;
        _generatedEmail = email;
        _generating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      AppNotification.showError(context, 'Could not generate code: $e');
    }
  }

  String get _shareMessage {
    final code = _generatedCode ?? '';
    return 'You have been invited to join on Reebaplus. '
        'Use this code to sign up: $code';
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: _generatedCode ?? ''));
    if (!mounted) return;
    AppNotification.showSuccess(context, 'Code copied to clipboard.');
  }

  Future<void> _shareSms() async {
    final uri = Uri.parse('sms:?body=${Uri.encodeComponent(_shareMessage)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (mounted) {
      AppNotification.showError(context, 'Could not open Messages.');
    }
  }

  Future<void> _shareWhatsApp() async {
    final uri = Uri.parse(
      'https://wa.me/?text=${Uri.encodeComponent(_shareMessage)}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      AppNotification.showError(context, 'Could not open WhatsApp.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final surface = t.colorScheme.surface;
    final text = t.colorScheme.onSurface;

    // Bottom padding is nav-only (deviceBottomPadding); MainLayout's Scaffold
    // resize handles keyboard avoidance, and a single SingleChildScrollView
    // handles overflow.
    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(16),
          context.getRSize(20),
          context.getRSize(20) + context.deviceBottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: context.getRSize(40),
                height: 4,
                margin: EdgeInsets.only(bottom: context.getRSize(16)),
                decoration: BoxDecoration(
                  color: t.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              _generatedCode == null ? 'Invite new staff' : 'Invite ready',
              style: TextStyle(
                color: text,
                fontSize: context.getRFontSize(18),
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: context.getRSize(16)),
            if (_generatedCode == null)
              _buildForm(context)
            else
              _buildGenerated(context),
          ],
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final mySlug = ref.watch(currentUserRoleProvider)?.slug;
    final allRoles = ref.watch(allRolesProvider).valueOrNull ?? const [];
    final roles = _invitableRoles(allRoles, mySlug);
    final allStores = ref.watch(allStoresProvider).valueOrNull ?? const [];

    // Manager: store is locked to their own. Resolve it once.
    final isManager = mySlug == 'manager';
    final myStoreId = ref.read(authProvider).currentUser?.storeId;
    if (isManager && _storeId == null && myStoreId != null) {
      _storeId = myStoreId;
    }
    final stores = isManager
        ? allStores.where((s) => s.id == myStoreId).toList()
        : allStores;

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppInput(
            controller: _emailCtrl,
            labelText: 'Email',
            hintText: 'name@example.com',
            keyboardType: TextInputType.emailAddress,
            prefixIcon: Icon(FontAwesomeIcons.envelope.data, size: 16),
            validator: (v) {
              final s = (v ?? '').trim();
              if (s.isEmpty) return 'Enter an email';
              if (!s.contains('@') || !s.contains('.')) {
                return 'Enter a valid email';
              }
              return null;
            },
          ),
          SizedBox(height: context.getRSize(16)),
          AppDropdown<String>(
            value: _roleId,
            labelText: 'Role',
            hintText: 'Select a role',
            items: roles
                .map((r) => DropdownMenuItem(value: r.id, child: Text(r.name)))
                .toList(),
            onChanged: (v) => setState(() => _roleId = v),
          ),
          SizedBox(height: context.getRSize(16)),
          AppDropdown<String>(
            value: _storeId,
            labelText: 'Store',
            hintText: 'Select a store',
            items: stores
                .map((s) => DropdownMenuItem(value: s.id, child: Text(s.name)))
                .toList(),
            onChanged: isManager ? (_) {} : (v) => setState(() => _storeId = v),
          ),
          SizedBox(height: context.getRSize(24)),
          AppButton(
            text: 'Generate code',
            icon: FontAwesomeIcons.ticket.data,
            isLoading: _generating,
            onPressed: _generating ? null : _generate,
          ),
        ],
      ),
    );
  }

  Widget _buildGenerated(BuildContext context) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Share this code with $_generatedEmail. It expires in 7 days '
          'and can be used once.',
          style: TextStyle(color: subtext, fontSize: context.getRFontSize(13)),
        ),
        SizedBox(height: context.getRSize(16)),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: context.getRSize(20)),
          decoration: BoxDecoration(
            color: t.colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: t.colorScheme.primary.withValues(alpha: 0.3),
            ),
          ),
          child: Center(
            child: Text(
              _generatedCode ?? '',
              style: TextStyle(
                color: text,
                fontSize: context.getRFontSize(30),
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        SizedBox(height: context.getRSize(20)),
        Row(
          children: [
            Expanded(
              child: AppButton(
                text: 'Copy',
                icon: FontAwesomeIcons.copy.data,
                variant: AppButtonVariant.secondary,
                onPressed: _copyCode,
              ),
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: AppButton(
                text: 'SMS',
                icon: FontAwesomeIcons.commentSms.data,
                variant: AppButtonVariant.outline,
                onPressed: _shareSms,
              ),
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: AppButton(
                text: 'WhatsApp',
                icon: FontAwesomeIcons.whatsapp.data,
                variant: AppButtonVariant.outline,
                onPressed: _shareWhatsApp,
              ),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(12)),
        AppButton(
          text: 'Done',
          variant: AppButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}
