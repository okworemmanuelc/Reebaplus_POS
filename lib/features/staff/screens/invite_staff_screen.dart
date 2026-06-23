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
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';

/// Detailed capabilities for each role slug, shown dynamically in the selector cards.
const Map<String, List<String>> _roleCapabilities = {
  'ceo': [
    'Full, unrestricted access to all business features and settings.',
    'Access profit & loss statement, statement of worth, and logs.',
    'Manage all stores, permissions, and roles.',
    'Invite, suspend, or delete any staff member.'
  ],
  'manager': [
    'Manage stores, inventory, suppliers, and customers.',
    'Record and self-approve expenses (up to the CEO-defined limit).',
    'Manage stock transfers and record damages.',
    'Invite and manage Cashiers and Stock keepers.'
  ],
  'cashier': [
    'Access Point of Sale (POS) to create orders and process checkouts.',
    'Add new customers, manage customer wallets, and record payments.',
    'View basic sales history and print receipts.',
    'Restricted from editing prices, viewing profit reports, or managing stock.'
  ],
  'stock_keeper': [
    'Add stock, record product damages, and count inventory.',
    'Initiate stock transfers between stores.',
    'Restricted from making sales, viewing customer wallets, or accessing financial reports.'
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
    return all;
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

    return GlassyScaffold(
      title: title,
      centerTitle: true,
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20) + context.deviceBottomPadding,
        ),
        child: _generatedCode == null
            ? _buildForm(context)
            : _buildGenerated(context),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final t = Theme.of(context);
    final mySlug = ref.watch(currentUserRoleProvider)?.slug;
    final allRoles = ref.watch(allRolesProvider).valueOrNull ?? const [];
    final roles = _invitableRoles(allRoles, mySlug);
    final allStores = ref.watch(allStoresProvider).valueOrNull ?? const [];

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
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              fontWeight: FontWeight.bold,
              color: t.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          // Custom vertical selector list of role capability cards
          ...roles.map((role) {
            final isSelected = _roleId == role.id;
            final capabilities = _roleCapabilities[role.slug] ?? const [];
            return _RoleSelectionCard(
              role: role,
              isSelected: isSelected,
              capabilities: capabilities,
              onTap: () => setState(() => _roleId = role.id),
            );
          }),
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
          'We\'ve emailed this code to $_generatedEmail. You can also copy or '
          'share it below. It expires in 7 days and can be used once.',
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

/// Custom selection card for role options that lists specific capabilities.
class _RoleSelectionCard extends StatelessWidget {
  final RoleData role;
  final bool isSelected;
  final List<String> capabilities;
  final VoidCallback onTap;

  const _RoleSelectionCard({
    required this.role,
    required this.isSelected,
    required this.capabilities,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.colorScheme.primary;

    return GlassyCard(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      padding: EdgeInsets.zero,
      backgroundColor: isSelected
          ? primaryColor.withValues(alpha: isDark ? 0.15 : 0.08)
          : (isDark
              ? theme.colorScheme.surface.withValues(alpha: 0.25)
              : theme.colorScheme.surface.withValues(alpha: 0.6)),
      border: Border.all(
        color: isSelected
            ? primaryColor
            : (isDark
                ? Colors.white.withValues(alpha: 0.05)
                : theme.colorScheme.primary.withValues(alpha: 0.05)),
        width: isSelected ? 2 : 1,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: context.getRSize(18),
                    height: context.getRSize(18),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected
                            ? primaryColor
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.4,
                              ),
                        width: 2,
                      ),
                    ),
                    child: isSelected
                        ? Center(
                            child: Container(
                              width: context.getRSize(10),
                              height: context.getRSize(10),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: primaryColor,
                              ),
                            ),
                          )
                        : null,
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Text(
                    role.name,
                    style: TextStyle(
                      fontSize: context.getRFontSize(15),
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  _RoleTag(role: role),
                ],
              ),
              if (capabilities.isNotEmpty) ...[
                SizedBox(height: context.getRSize(12)),
                ...capabilities.map(
                  (cap) => Padding(
                    padding: EdgeInsets.only(bottom: context.getRSize(6)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            top: context.getRSize(3),
                            right: context.getRSize(8),
                          ),
                          child: Icon(
                            FontAwesomeIcons.circleCheck.data,
                            size: context.getRSize(12),
                            color: isSelected
                                ? primaryColor
                                : theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.6),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            cap,
                            style: TextStyle(
                              fontSize: context.getRFontSize(13),
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleTag extends StatelessWidget {
  final RoleData? role;
  const _RoleTag({required this.role});

  @override
  Widget build(BuildContext context) {
    final color = roleTagColor(role?.slug);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        role?.name ?? 'Unknown',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
