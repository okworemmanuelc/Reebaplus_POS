import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/logger.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/role_guard.dart';
import 'package:reebaplus_pos/features/invite/services/invite_api_service.dart';
import 'package:reebaplus_pos/features/invite/widgets/code_share_card.dart';
import 'package:reebaplus_pos/features/invite/widgets/invite_modal.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_constants.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_details_screen.dart';
import 'package:reebaplus_pos/features/staff/widgets/invite_pending_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';

const String _kAllWarehouses = '__all__';

// Pending invites carry the legacy `inviteeName = 'Unknown'` sentinel until
// the staff member completes redemption (the wizard writes the real name).
// Surface the email instead so the row is identifiable in the meantime.
String _displayNameForInvite(InviteData invite) {
  final n = invite.inviteeName.trim();
  if (n.isEmpty || n.toLowerCase() == 'unknown') return invite.email;
  return n;
}

class StaffListItem {
  final UserData? user;
  final InviteData? invite;
  final String status;
  final int tier;
  final String name;
  final String roleLabel;
  final String? avatarColor;
  final String warehouseId;

  StaffListItem.fromUser(this.user, RoleOption roleInfo)
    : invite = null,
      status = 'active',
      tier = roleInfo.tier,
      name = user!.name,
      roleLabel = roleInfo.label,
      avatarColor = user.avatarColor,
      warehouseId = user.warehouseId ?? _kAllWarehouses;

  StaffListItem.fromInvite(this.invite, RoleOption roleInfo)
    : user = null,
      status = invite!.status,
      tier = roleInfo.tier,
      name = _displayNameForInvite(invite),
      roleLabel = roleInfo.label,
      avatarColor = null,
      warehouseId = invite.warehouseId ?? _kAllWarehouses;
}

class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});

  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  String _searchQuery = '';
  String _selectedWarehouseFilter = _kAllWarehouses;
  List<WarehouseData> _warehouses = [];
  List<UserData> _rawUsers = [];
  List<InviteData> _rawInvites = [];
  List<StaffListItem> _items = [];
  bool _loading = true;
  StreamSubscription<List<UserData>>? _usersSub;
  StreamSubscription<List<InviteData>>? _invitesSub;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;
  Color get _card => Theme.of(context).cardColor;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    db.select(db.warehouses).get().then((ws) {
      if (mounted) setState(() => _warehouses = ws);
    });
    _usersSub = db.select(db.users).watch().listen((data) {
      if (mounted) {
        _rawUsers = data;
        _updateItems();
      }
    });
    _invitesSub = db.select(db.invites).watch().listen((data) {
      if (mounted) {
        _rawInvites = data;
        _updateItems();
      }
    });
    _loading = false;
  }

  void _updateItems() {
    final List<StaffListItem> combined = [
      ..._rawUsers.map((u) => StaffListItem.fromUser(u, roleFor(u.role))),
      ..._rawInvites
          .where((i) => i.status != 'accepted' && i.status != 'revoked')
          .map((i) => StaffListItem.fromInvite(i, roleFor(i.role))),
    ];
    setState(() => _items = combined);
  }

  @override
  void dispose() {
    _usersSub?.cancel();
    _invitesSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(authProvider).currentUser;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: const MenuButton(),
        title: const AppBarHeader(
          icon: FontAwesomeIcons.userTie,
          title: 'Staff Management',
          subtitle: 'Manage your team & roles',
        ),
        actions: const [NotificationBell(), SizedBox(width: 8)],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: AppInput(
              onChanged: (v) => setState(() => _searchQuery = v),
              hintText: 'Search staff by name...',
              prefixIcon: Icon(
                FontAwesomeIcons.magnifyingGlass,
                size: 16,
                color: _subtext,
              ),
              fillColor: _bg,
            ),
          ),
        ),
      ),
      drawer: const AppDrawer(activeRoute: 'staff'),
      body: _buildBody(currentUser),
      floatingActionButton: RoleGuard(
        minTier: 5,
        fallback: const SizedBox.shrink(),
        child: AppFAB(
          onPressed: () => _showStaffSheet(context),
          icon: FontAwesomeIcons.plus,
          label: 'Add Staff',
        ),
      ),
    );
  }

  Widget _buildBody(UserData? currentUser) {
    final listRaw = _items;
    var list = [...listRaw];

    if (_selectedWarehouseFilter != _kAllWarehouses) {
      list = list
          .where((u) => u.warehouseId == _selectedWarehouseFilter)
          .toList();
    }
    if (_searchQuery.isNotEmpty) {
      list = list
          .where(
            (u) => u.name.toLowerCase().contains(_searchQuery.toLowerCase()),
          )
          .toList();
    }

    return Column(
      children: [
        _buildWarehouseFilters(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        FontAwesomeIcons.usersSlash,
                        size: 48,
                        color: _subtext.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No staff found',
                        style: TextStyle(color: _subtext, fontSize: 16),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  children: [
                    for (final tier in [6, 5, 4, 3, 2, 1]) ...[
                      if (list.any((u) => u.tier == tier)) ...[
                        _buildSectionHeader(
                          tier,
                          list.where((u) => u.tier == tier).length,
                        ),
                        const SizedBox(height: 8),
                        ...list
                            .where((u) => u.tier == tier)
                            .map(
                              (u) => _buildStaffCard(context, u, currentUser),
                            ),
                        const SizedBox(height: 16),
                      ],
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildWarehouseFilters() {
    return SizedBox(
      height: 50,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _filterChip('All', _kAllWarehouses),
          for (final w in _warehouses) _filterChip(w.name, w.id),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String id) {
    final active = _selectedWarehouseFilter == id;
    return GestureDetector(
      onTap: () => setState(() => _selectedWarehouseFilter = id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: active ? blueMain : _surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? blueMain : _border),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : _text,
              fontSize: 13,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(int tier, int count) {
    final roleInfo = roleOptions.firstWhere(
      (r) => r.tier == tier,
      orElse: () => roleOptions.last,
    );
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: roleInfo.color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '  ${roleInfo.label.toUpperCase()}S',
          style: TextStyle(
            color: _subtext,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        const Spacer(),
        Text(
          '$count members',
          style: TextStyle(
            color: _subtext.withValues(alpha: 0.5),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildStaffCard(
    BuildContext context,
    StaffListItem item,
    UserData? currentUser,
  ) {
    final roleInfo = roleFor(item.user?.role ?? item.invite?.role ?? '');
    final avatarColor = item.avatarColor != null
        ? _parseColor(item.avatarColor!) ?? roleInfo.color
        : roleInfo.color;
    final initials = _initials(item.name);

    // Authorization check: Staff below this one in tier cannot view profile
    final isDisabled = currentUser != null && currentUser.roleTier < item.tier;

    return Opacity(
      opacity: isDisabled ? 0.5 : 1.0,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: InkWell(
          onTap: isDisabled
              ? null
              : () {
                  if (item.status == 'active' && item.user != null) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => StaffDetailsScreen(
                          user: item.user!,
                          warehouses: _warehouses,
                        ),
                      ),
                    );
                  } else if (item.status == 'pending' && item.invite != null) {
                    _showInvitePendingSheet(item.invite!);
                  }
                },
          onLongPress: (isDisabled || item.status != 'active')
              ? null
              : () => _showStaffActions(context, item),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(14)),
            child: Row(
              children: [
                Container(
                  width: context.getRSize(48),
                  height: context.getRSize(48),
                  decoration: BoxDecoration(
                    color: avatarColor.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: avatarColor.withValues(alpha: 0.5),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      initials,
                      style: TextStyle(
                        color: avatarColor,
                        fontWeight: FontWeight.bold,
                        fontSize: context.getRFontSize(16),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: context.getRSize(14)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: TextStyle(
                          color: _text,
                          fontWeight: FontWeight.bold,
                          fontSize: context.getRFontSize(15),
                        ),
                      ),
                      SizedBox(height: context.getRSize(4)),
                      Row(
                        children: [
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: context.getRSize(8),
                              vertical: context.getRSize(2),
                            ),
                            decoration: BoxDecoration(
                              color: roleInfo.color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              roleInfo.label,
                              style: TextStyle(
                                color: roleInfo.color,
                                fontSize: context.getRFontSize(11),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (item.status != 'active') ...[
                            SizedBox(width: context.getRSize(8)),
                            _InviteStatusBadge(status: item.status),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (!isDisabled && item.status == 'active')
                  RoleGuard(
                    minTier: 5,
                    fallback: const SizedBox.shrink(),
                    child: IconButton(
                      onPressed: () => _showStaffActions(context, item),
                      icon: Icon(
                        FontAwesomeIcons.ellipsisVertical,
                        size: context.getRSize(16),
                        color: _subtext.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showStaffSheet(BuildContext context, {UserData? user}) {
    if (user == null) {
      // New staff: cloud-first invite flow with native share-sheet handoff.
      // Modal looks up the business name itself from local Drift.
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).cardColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => InviteModal(warehouses: _warehouses),
      );
      return;
    }
    // Editing an existing staff row keeps the original form (PIN reset etc.).
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _StaffFormSheet(user: user, warehouses: _warehouses),
    );
  }

  void _showStaffActions(BuildContext context, StaffListItem item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _StaffActionSheet(
        item: item,
        onEdit: () {
          Navigator.pop(ctx);
          if (item.user != null) _showStaffSheet(context, user: item.user);
        },
        onDelete: () {
          Navigator.pop(ctx);
          if (item.user != null) _confirmDelete(context, item.user!);
        },
        onView: () {
          Navigator.pop(ctx);
          if (item.user == null) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  StaffDetailsScreen(user: item.user!, warehouses: _warehouses),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showInvitePendingSheet(InviteData invite) async {
    final db = ref.read(databaseProvider);
    final bizId = ref.read(authProvider).currentUser?.businessId;
    String businessName = 'your business';
    if (bizId != null) {
      final biz = await (db.select(db.businesses)
            ..where((b) => b.id.equals(bizId))
            ..limit(1))
          .getSingleOrNull();
      if (biz != null) businessName = biz.name;
    }
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => InvitePendingSheet(
        invite: invite,
        warehouses: _warehouses,
        businessName: businessName,
        onRegenerate: () {
          Navigator.pop(ctx);
          _handleRegenerateInvite(invite);
        },
        onRevoke: () {
          Navigator.pop(ctx);
          _handleRevokeInvite(invite);
        },
      ),
    );
  }

  Future<void> _handleRegenerateInvite(InviteData invite) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Generate a new code?',
          style: TextStyle(color: _text, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'The old code will stop working immediately. Share the new code '
          'with the staff member to invite.',
          style: TextStyle(color: _subtext),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Generate',
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Non-dismissible loader so the user gets feedback during the network
    // round-trip instead of staring at a blank screen.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Text(
              'Generating new code…',
              style: TextStyle(color: _text),
            ),
          ],
        ),
      ),
    );
    var loaderOpen = true;
    void closeLoader() {
      if (loaderOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        loaderOpen = false;
      }
    }

    final api = ref.read(inviteApiServiceProvider);
    final result = await api.regenerateInvite(invite.id);
    if (!mounted) {
      loaderOpen = false;
      return;
    }
    closeLoader();

    if (result is InviteApiErr<Map<String, dynamic>>) {
      if (result.details != null) {
        AppLogger.error(
          'regenerate_invite_code failed: ${result.code.name} ${result.details}',
        );
      }
      AppNotification.showError(context, result.message);
      return;
    }
    final ok = result as InviteApiOk<Map<String, dynamic>>;
    final newHumanCode = ok.data['human_code']?.toString();
    if (newHumanCode == null || newHumanCode.isEmpty) {
      AppNotification.showError(
        context,
        'Code regenerated, but the response was empty. Reload to see the latest.',
      );
      return;
    }

    // Seed the freshly minted invite row into local Drift via the same
    // canonical-restore seam redeem-invite uses, so the staff list reflects
    // it without waiting for the next sync pull.
    final inviteRow = ok.data['invite'];
    if (inviteRow is Map) {
      try {
        await ref.read(supabaseSyncServiceProvider).applyServerResponse(
              'regenerate_invite',
              {'invite': Map<String, dynamic>.from(inviteRow)},
            );
      } catch (_) {
        // Best-effort — next pull catches up.
      }
      if (!mounted) return;
    }

    final db = ref.read(databaseProvider);
    final bizId = ref.read(authProvider).currentUser?.businessId;
    String businessName = 'your business';
    if (bizId != null) {
      final biz = await (db.select(db.businesses)
            ..where((b) => b.id.equals(bizId))
            ..limit(1))
          .getSingleOrNull();
      if (biz != null) businessName = biz.name;
    }
    if (!mounted) return;

    final inviteeName = invite.inviteeName.trim();
    final recipientName =
        (inviteeName.isNotEmpty && inviteeName != 'Unknown') ? inviteeName : null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: CodeShareCard(
          humanCode: newHumanCode,
          businessName: businessName,
          recipientName: recipientName,
          title: 'New code generated',
          subtitle: 'The previous code is no longer valid.',
          onDone: () => Navigator.pop(ctx),
        ),
      ),
    );
  }

  Future<void> _handleRevokeInvite(InviteData invite) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Revoke this invitation?',
          style: TextStyle(color: _text, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'The staff member will no longer be able to use the code.',
          style: TextStyle(color: _subtext),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Revoke',
            variant: AppButtonVariant.danger,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final api = ref.read(inviteApiServiceProvider);
    final result = await api.revokeInvite(invite.id);
    if (!mounted) return;
    if (result is InviteApiErr<Map<String, dynamic>>) {
      AppNotification.showError(context, result.message);
      return;
    }

    // Seed the revoked status into local Drift via the same canonical-
    // restore seam regenerate/redeem use, so _updateItems's
    // `status != 'revoked'` filter drops the row without waiting for
    // the next sync pull.
    final ok = result as InviteApiOk<Map<String, dynamic>>;
    final inviteRow = ok.data['invite'];
    if (inviteRow is Map) {
      try {
        await ref.read(supabaseSyncServiceProvider).applyServerResponse(
              'revoke_invite',
              {'invite': Map<String, dynamic>.from(inviteRow)},
            );
      } catch (_) {
        // Best-effort — next pull catches up.
      }
      if (!mounted) return;
    }
    AppNotification.showSuccess(context, 'Invite revoked.');
  }

  void _confirmDelete(BuildContext context, UserData user) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Delete Staff',
          style: TextStyle(color: _text, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Are you sure you want to remove ${user.name} from the system?',
          style: TextStyle(color: _subtext),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(context),
          ),
          AppButton(
            text: 'Delete',
            variant: AppButtonVariant.danger,
            onPressed: () async {
              Navigator.pop(context);
              // Stub — no DB delete in this version
            },
          ),
        ],
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.substring(0, name.length.clamp(0, 2)).toUpperCase();
  }

  Color? _parseColor(String color) {
    try {
      return Color(int.parse(color.replaceAll('#', 'FF'), radix: 16));
    } catch (_) {
      return null;
    }
  }
}

class _StaffFormSheet extends ConsumerStatefulWidget {
  final UserData? user;
  final List<WarehouseData> warehouses;
  const _StaffFormSheet({this.user, required this.warehouses});

  @override
  ConsumerState<_StaffFormSheet> createState() => _StaffFormSheetState();
}

class _StaffFormSheetState extends ConsumerState<_StaffFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _pinCtrl;
  late RoleOption _selectedRole;
  String? _selectedWarehouseId;
  bool _showPin = false;
  final bool _isSaving = false;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _nameCtrl = TextEditingController(text: u?.name ?? '');
    _emailCtrl = TextEditingController(text: u?.email ?? '');
    // PIN is stored as a PBKDF2 hash post-v35, so pre-filling from u.pin
    // would surface the literal '__HASHED__' sentinel and fail the 6-digit
    // validator. Admin must re-enter a fresh 6-digit PIN to change it.
    _pinCtrl = TextEditingController();
    _selectedRole = u != null
        ? roleFor(u.role)
        : roleOptions[3]; // default Cashier
    _selectedWarehouseId = u?.warehouseId;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        ),
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: _subtext.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  widget.user == null ? 'Add New Staff' : 'Edit Staff Details',
                  style: TextStyle(
                    color: _text,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),

                AppInput(
                  controller: _nameCtrl,
                  labelText: 'Full Name',
                  hintText: 'Enter full name',
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Name is required' : null,
                ),
                const SizedBox(height: 16),
                AppInput(
                  controller: _emailCtrl,
                  labelText: 'Email Address',
                  hintText: 'Enter email address',
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Email is required';
                    if (!RegExp(
                      r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$',
                    ).hasMatch(v)) {
                      return 'Enter a valid email';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 16),

                // PIN field only shown when editing an existing staff member.
                // New staff set their own 6-digit PIN on first login.
                if (widget.user != null)
                  AppInput(
                    controller: _pinCtrl,
                    labelText: 'Access PIN (6 Digits)',
                    hintText: 'Enter 6-digit PIN',
                    obscureText: !_showPin,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _showPin = !_showPin),
                      icon: Icon(
                        _showPin
                            ? FontAwesomeIcons.eyeSlash
                            : FontAwesomeIcons.eye,
                        size: 16,
                        color: _subtext,
                      ),
                    ),
                    validator: (v) => v == null || v.length != 6
                        ? 'PIN must be 6 digits'
                        : null,
                  ),

                const SizedBox(height: 16),

                AppDropdown<RoleOption>(
                  labelText: 'Role & Access Level',
                  value: _selectedRole,
                  items: roleOptions.map((r) {
                    return DropdownMenuItem<RoleOption>(
                      value: r,
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: r.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              r.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (r) => setState(() => _selectedRole = r!),
                ),

                const SizedBox(height: 16),

                AppDropdown<String>(
                  labelText: 'Assigned Warehouse',
                  value: _selectedWarehouseId,
                  hintText: 'Select Warehouse',
                  items: widget.warehouses.map((w) {
                    return DropdownMenuItem<String>(
                      value: w.id,
                      child: Text(w.name),
                    );
                  }).toList(),
                  onChanged: (id) => setState(() => _selectedWarehouseId = id!),
                ),

                const SizedBox(height: 32),

                // Submit Button
                AppButton(
                  text: widget.user == null
                      ? (_isSaving ? 'Sending...' : 'Send Invite')
                      : 'Save Changes',
                  onPressed: _isSaving ? () {} : _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedWarehouseId == null) return;

    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    final role = _selectedRole.value;
    final tier = _selectedRole.tier;

    // Non-managers cannot be added to a warehouse that has no manager yet.
    if (tier < 4) {
      final db = ref.read(databaseProvider);
      final staffInWarehouse = await (db.select(
        db.users,
      )..where((u) => u.warehouseId.equals(_selectedWarehouseId!))).get();

      // Exclude the user being edited, then count managers.
      final otherManagers = staffInWarehouse
          .where(
            (u) =>
                u.roleTier >= 5 &&
                (widget.user == null || u.id != widget.user!.id),
          )
          .toList();

      if (otherManagers.isEmpty) {
        if (!mounted) return;
        final matchedWarehouse = widget.warehouses
            .where((w) => w.id == _selectedWarehouseId)
            .firstOrNull;
        final warehouseName = matchedWarehouse?.name ?? 'this warehouse';
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                const Icon(
                  FontAwesomeIcons.triangleExclamation,
                  color: Color(0xFFF97316),
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(
                  'No Manager Assigned',
                  style: TextStyle(
                    color: _text,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            content: Text(
              '"$warehouseName" does not have a manager yet.\n\n'
              'You must assign a Manager (or higher) to this warehouse before adding regular staff.',
              style: TextStyle(color: _subtext, height: 1.5),
            ),
            actions: [
              AppButton(
                text: 'Got it',
                onPressed: () => Navigator.pop(ctx),
                size: AppButtonSize.small,
              ),
            ],
          ),
        );
        return;
      }
    }

    final matchedWarehouse = widget.warehouses
        .where((w) => w.id == _selectedWarehouseId)
        .firstOrNull;
    final warehouseName = matchedWarehouse?.name ?? 'the warehouse';

    if (widget.user == null) {
      // New-staff path now lives in InviteModal (server-validated invite +
      // native share-sheet handoff). _StaffFormSheet is editing-only — this
      // branch is unreachable from the redesigned _showStaffSheet, but the
      // assertion keeps an accidental future caller from silently no-op'ing.
      assert(false, '_StaffFormSheet must be opened with a non-null user.');
      return;
    } else {
      // Update existing staff member
      final db = ref.read(databaseProvider);
      final userComp = UsersCompanion(
        id: Value(widget.user!.id),
        name: Value(name),
        email: Value(email),
        role: Value(role),
        roleTier: Value(tier),
        warehouseId: Value(_selectedWarehouseId),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (db.update(
        db.users,
      )..where((u) => u.id.equals(widget.user!.id))).write(userComp);
      await db.syncDao.enqueueUpsert('users', userComp);
      // PIN goes through the canonical hash-and-write path so it is never
      // persisted in cleartext.
      await ref.read(authProvider).setUserPin(widget.user!.id, pin);
    }

    if (!mounted) return;
    Navigator.pop(context); // Close sheet on update
    AppNotification.showSuccess(
      context,
      '$name has been successfully assigned to $warehouseName.',
    );
  }
}

class _StaffActionSheet extends ConsumerWidget {
  final StaffListItem item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onView;

  const _StaffActionSheet({
    required this.item,
    required this.onEdit,
    required this.onDelete,
    required this.onView,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Color surfaceColor = Theme.of(context).colorScheme.surface;
    final Color textColor = Theme.of(context).colorScheme.onSurface;
    final Color subtextColor =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;

    final roleInfo = roleFor(item.user?.role ?? item.invite?.role ?? '');
    final avatarColor = item.avatarColor != null
        ? _parseColor(item.avatarColor!) ?? roleInfo.color
        : roleInfo.color;

    return Container(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 40,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 48,
              height: 5,
              decoration: BoxDecoration(
                color: subtextColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: avatarColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: avatarColor.withValues(alpha: 0.3),
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Text(
                    _initials(item.name),
                    style: TextStyle(
                      color: avatarColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      roleInfo.label,
                      style: TextStyle(
                        color: roleInfo.color,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Text(
            'AVAILABLE ACTIONS',
            style: TextStyle(
              color: subtextColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          // Pending invites have their own dedicated bottom sheet
          // (InvitePendingSheet); the action sheet here only runs for
          // active staff. See _showInvitePendingSheet in _StaffScreenState.
          ...[
            _actionTile(
              context,
              icon: FontAwesomeIcons.userPen,
              label: 'View Full Profile',
              subtitle: 'Check performance & history',
              color: Theme.of(context).colorScheme.primary,
              onTap: onView,
              isDark: Theme.of(context).brightness == Brightness.dark,
              bg: bgColor,
              text: textColor,
              subtext: subtextColor,
            ),
            const SizedBox(height: 12),
            _actionTile(
              context,
              icon: FontAwesomeIcons.penToSquare,
              label: 'Edit Details',
              subtitle: 'Update role or access PIN',
              color: Colors.orange,
              onTap: onEdit,
              isDark: Theme.of(context).brightness == Brightness.dark,
              bg: bgColor,
              text: textColor,
              subtext: subtextColor,
            ),
            const SizedBox(height: 12),
            _actionTile(
              context,
              icon: FontAwesomeIcons.trashCan,
              label: 'Terminate Access',
              subtitle: 'Permanently remove from team',
              color: Theme.of(context).colorScheme.error,
              onTap: onDelete,
              isDark: Theme.of(context).brightness == Brightness.dark,
              bg: bgColor,
              text: textColor,
              subtext: subtextColor,
              isDanger: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
    required bool isDark,
    required Color bg,
    required Color text,
    required Color subtext,
    bool isDanger = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDanger ? color.withValues(alpha: 0.1) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isDanger ? color : text,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: subtext.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: subtext.withValues(alpha: 0.3),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    if (name.isEmpty) return '??';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.substring(0, name.length.clamp(0, 2)).toUpperCase();
  }

  Color? _parseColor(String color) {
    try {
      return Color(int.parse(color.replaceAll('#', 'FF'), radix: 16));
    } catch (_) {
      return null;
    }
  }
}

class _InviteStatusBadge extends StatelessWidget {
  final String status;

  const _InviteStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final isPending = status == 'pending';
    final color = isPending ? Colors.amber.shade700 : Colors.red;
    final label = isPending ? 'Invitation Pending' : status.toUpperCase();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(2),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: context.getRFontSize(10),
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
