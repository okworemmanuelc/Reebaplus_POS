import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/features/staff/widgets/staff_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Detailed capabilities for each role slug, shown dynamically in the selector cards.
const Map<String, List<String>> _roleCapabilities = {
  'ceo': [
    'Full, unrestricted access to all business features and settings.',
    'Access profit & loss statement, statement of worth, and logs.',
    'Manage all stores, permissions, and roles.',
    'Invite, suspend, or delete any staff member.',
  ],
  'manager': [
    'Manage stores, inventory, suppliers, and customers.',
    'Record and self-approve expenses (up to the CEO-defined limit).',
    'Manage stock transfers and record damages.',
    'Invite and manage Cashiers and Stock keepers.',
  ],
  'cashier': [
    'Access Point of Sale (POS) to create orders and process checkouts.',
    'Add new customers, manage customer credit balances, and record payments.',
    'View basic sales history and print receipts.',
    'Restricted from editing prices, viewing profit reports, or managing stock.',
  ],
  'stock_keeper': [
    'Add stock, record product damages, and count inventory.',
    'Initiate stock transfers between stores.',
    'Restricted from making sales, viewing customer credit balances, or accessing financial reports.',
  ],
  // #140 — the seeded Driver role. Listed last because roles are shown in tier
  // order (CEO → Manager → Cashier → Stock keeper → Driver) via `roleRank`,
  // never alphabetically.
  'driver': [
    'Sell from the van they are assigned to, on the road.',
    'Restricted to that van — they never see or sell store stock.',
    'Cannot load a van, record their own remittance, or close a trip; a manager does all three.',
  ],
};

/// Invite new staff screen (replaces the old InviteStaffSheet modal).
/// Gated by `staff.invite` permission.
class InviteStaffScreen extends ConsumerStatefulWidget {
  const InviteStaffScreen({super.key});

  @override
  ConsumerState<InviteStaffScreen> createState() => _InviteStaffScreenState();
}

class _InviteStaffScreenState extends ConsumerState<InviteStaffScreen> {
  final _emailCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _roleId;
  String? _storeId;
  bool _generating = false;

  String? _generatedCode;
  String? _generatedEmail;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  List<RoleData> _invitableRoles(List<RoleData> all, String? mySlug) {
    if (mySlug == 'manager') {
      return all
          .where((r) => r.slug == 'cashier' || r.slug == 'stock_keeper')
          .toList();
    }
    // The Driver role is not offered while Van Sales is switched off.
    return rolesOnOffer(all);
  }

  String _randomCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random.secure();
    return List.generate(8, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Future<void> _generate() async {
    if (!_formKey.currentState!.validate()) return;
    if (!ref.read(currentUserPermissionsProvider).contains('staff.invite')) {
      AppNotification.showError(
        context,
        'You don\'t have permission to do that.',
      );
      return;
    }
    // The store must still be one on offer — a van is not while Van Sales is
    // switched off, however `_storeId` was set.
    final offeredStoreIds = {
      for (final s in assignableStores(
        ref.read(allStoresProvider).valueOrNull ?? const <StoreData>[],
      ))
        s.id,
    };
    if (_roleId == null ||
        _storeId == null ||
        !offeredStoreIds.contains(_storeId)) {
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
    final title = _generatedCode == null ? 'Invite Staff' : 'Invite Ready';

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: StaffTopBar(
          key: StaffKeys.topBar,
          height: staffTopBarHeight(context),
          header: ScreenHeader(
            icon: AppIcons.userAdd,
            title: title,
            leading: const StaffBackButton(key: StaffKeys.inviteBack),
          ),
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: StaffColumn(
            top: context.getRSize(20),
            bottom: context.getRSize(20) + context.deviceBottomPadding,
            children: [
              _generatedCode == null
                  ? _buildForm(context)
                  : _buildGenerated(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final t = Theme.of(context);
    final mySlug = ref.watch(currentUserRoleProvider)?.slug;
    final allRoles = ref.watch(allRolesProvider).valueOrNull ?? const [];
    final roles = _invitableRoles(allRoles, mySlug);
    // Vans are not offered while Van Sales is switched off.
    final allStores = assignableStores(
      ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[],
    );

    final isManager = mySlug == 'manager';
    final myStoreId = ref.read(authProvider).currentUser?.storeId;
    if (isManager &&
        _storeId == null &&
        myStoreId != null &&
        allStores.any((s) => s.id == myStoreId)) {
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
            prefixIcon: const Icon(AppIcons.email, size: 16),
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
            value: _storeId,
            labelText: 'Store',
            hintText: 'Select a store',
            items: stores
                .map((s) => DropdownMenuItem(value: s.id, child: Text(s.name)))
                .toList(),
            onChanged: isManager ? (_) {} : (v) => setState(() => _storeId = v),
          ),
          SizedBox(height: context.getRSize(20)),
          Text(
            'Select Role & View Capabilities',
            style: context
                .boldStyle(14)
                .copyWith(color: t.colorScheme.onSurface),
          ),
          SizedBox(height: context.getRSize(8)),
          // Custom vertical selector list of role capability cards
          ...roles.map((role) {
            final isSelected = _roleId == role.id;
            final capabilities = _roleCapabilities[role.slug] ?? const [];
            return Padding(
              padding: EdgeInsets.only(bottom: context.getRSize(12)),
              child: StaffRoleOptionCard(
                key: StaffKeys.roleCard(role.id),
                roleName: role.name,
                roleSlug: role.slug,
                capabilities: capabilities,
                selected: isSelected,
                onTap: () => setState(() => _roleId = role.id),
              ),
            );
          }),
          SizedBox(height: context.getRSize(24)),
          AppButton(
            text: 'Generate code',
            icon: AppIcons.discount,
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
          'We\'ve emailed this code to $_generatedEmail. You can also copy or '
          'share it below. It expires in 7 days and can be used once.',
          style: context.regularStyle(13).copyWith(color: subtext),
        ),
        SizedBox(height: context.getRSize(16)),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: context.getRSize(20)),
          decoration: AppDecorations.card(context).copyWith(
            color:
                t.extension<AppSchemeColors>()?.primaryTint ??
                t.colorScheme.primary.withValues(alpha: 0.12),
            border: Border.all(color: t.colorScheme.primary),
          ),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _generatedCode ?? '',
                key: StaffKeys.inviteCode,
                style: context.monoStyle.copyWith(
                  color: text,
                  fontSize: context.getRFontSize(30),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 6,
                ),
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
                icon: AppIcons.copy,
                variant: AppButtonVariant.secondary,
                onPressed: _copyCode,
              ),
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: AppButton(
                text: 'SMS',
                icon: AppIcons.sms,
                variant: AppButtonVariant.outline,
                onPressed: _shareSms,
              ),
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: AppButton(
                text: 'WhatsApp',
                icon: AppIcons.whatsapp,
                variant: AppButtonVariant.outline,
                onPressed: _shareWhatsApp,
              ),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(20)),
        AppButton(
          text: 'Done',
          variant: AppButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}
