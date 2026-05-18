import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/invite/services/invite_api_service.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/role_guard.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_constants.dart';

class StaffDetailsScreen extends ConsumerStatefulWidget {
  final UserData user;
  final List<WarehouseData> warehouses;

  const StaffDetailsScreen({
    super.key,
    required this.user,
    required this.warehouses,
  });

  @override
  ConsumerState<StaffDetailsScreen> createState() => _StaffDetailsScreenState();
}

class _StaffDetailsScreenState extends ConsumerState<StaffDetailsScreen> {
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;
  List<OrderData> _staffOrders = [];
  StreamSubscription<List<OrderData>>? _ordersSub;
  bool _contentReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _contentReady = true);
        final db = ref.read(databaseProvider);
        _ordersSub =
            (db.select(db.orders)
                  ..where((t) => t.staffId.equals(widget.user.id)))
                .watch()
                .listen((data) {
                  if (mounted) setState(() => _staffOrders = data);
                });
      }
    });
  }

  @override
  void dispose() {
    _ordersSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final avatarColor =
        _parseColor(widget.user.avatarColor) ??
        Theme.of(context).colorScheme.primary;
    final warehouseName = widget.warehouses
            .where((w) => w.id == widget.user.warehouseId)
            .firstOrNull
            ?.name ??
        'Unassigned';

    if (!_contentReady) {
      return SharedScaffold(
        activeRoute: 'staff',
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _surface,
          elevation: 0,
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: _text,
              size: 20,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          title: AppBarHeader(
            icon: FontAwesomeIcons.userTie,
            title: widget.user.name,
            subtitle: widget.user.role.toUpperCase(),
          ),
        ),
        body: Center(
          child: CircularProgressIndicator(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }

    return SharedScaffold(
      activeRoute: 'staff',
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: _text, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: AppBarHeader(
          icon: FontAwesomeIcons.userTie,
          title: widget.user.name,
          subtitle: widget.user.role.toUpperCase(),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 600;
          return ListView(
            padding: EdgeInsets.all(rSize(context, 20)).copyWith(
              bottom: rSize(context, 20) + context.bottomInset,
            ),
            children: [
              _buildProfileHeader(avatarColor, warehouseName),
              SizedBox(height: rSize(context, 24)),
              _buildVerificationSection(),
              _buildPerformanceMetrics(isWide),
              SizedBox(height: rSize(context, 24)),
              _buildSystemInfo(),
              SizedBox(height: rSize(context, 100)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildProfileHeader(Color color, String warehouse) {
    return Container(
      padding: EdgeInsets.all(rSize(context, 24)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          Container(
            width: rSize(context, 80),
            height: rSize(context, 80),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.3), width: 3),
            ),
            child: Center(
              child: Text(
                _initials(widget.user.name),
                style: TextStyle(
                  color: color,
                  fontSize: rFontSize(context, 24),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SizedBox(height: rSize(context, 16)),
          Text(
            widget.user.name,
            style: TextStyle(
              fontSize: rFontSize(context, 20),
              fontWeight: FontWeight.w900,
              color: _text,
            ),
          ),
          RoleGuard(
            minTier: 5,
            fallback: _buildRoleTag(roleFor(widget.user.role)),
            child: InkWell(
              onTap: () => _showRolePicker(context),
              borderRadius: BorderRadius.circular(20),
              child: _buildRoleTag(
                roleFor(widget.user.role),
                isInteractive: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleTag(RoleOption role, {bool isInteractive = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: role.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: role.color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            role.label.toUpperCase(),
            style: TextStyle(
              fontSize: rFontSize(context, 11),
              fontWeight: FontWeight.bold,
              color: role.color,
            ),
          ),
          if (isInteractive) ...[
            const SizedBox(width: 8),
            Icon(Icons.edit_rounded, size: 12, color: role.color),
          ],
        ],
      ),
    );
  }

  void _showRolePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Container(
        padding: EdgeInsets.fromLTRB(24, 24, 24, context.bottomInset + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Change Role',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: _text,
              ),
            ),
            const SizedBox(height: 16),
            ...roleOptions.map(
              (role) => ListTile(
                leading: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: role.color,
                    shape: BoxShape.circle,
                  ),
                ),
                title: Text(role.label, style: TextStyle(color: _text)),
                onTap: () {
                  Navigator.pop(context);
                  if (role.value != widget.user.role) {
                    _confirmRoleChange(role);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmRoleChange(RoleOption newRole) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surface,
        title: Text('Confirm Role Change', style: TextStyle(color: _text)),
        content: Text(
          'Are you sure you want to change ${widget.user.name}\'s role to ${newRole.label}?',
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
            text: 'Change Role',
            onPressed: () async {
              Navigator.pop(context);
              // Stub — no DB write in this version
              AppNotification.showSuccess(
                context,
                'Role updated to ${newRole.label}',
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildVerificationSection() {
    final members = ref.watch(currentBusinessMembersProvider).valueOrNull;
    if (members == null) return const SizedBox.shrink();
    final member =
        members.where((m) => m.userId == widget.user.id).firstOrNull;
    if (member == null) return const SizedBox.shrink();
    if (member.role == 'ceo') return const SizedBox.shrink();

    final status = member.verificationStatus;
    final dueAt = member.verificationDueAt;

    Color tint;
    IconData icon;
    String headline;
    String subline;
    bool showInfoIcon = false;
    bool showExtendButton = false;

    if (status == 'approved') {
      tint = AppColors.success;
      icon = FontAwesomeIcons.circleCheck;
      headline = 'Verified';
      subline = 'Identity confirmed.';
    } else if (status == 'pending_review') {
      tint = Colors.amber.shade700;
      icon = FontAwesomeIcons.clock;
      headline = 'Under review';
      subline = 'Documents are awaiting admin review.';
    } else if (status == 'rejected') {
      tint = Colors.red;
      icon = FontAwesomeIcons.circleXmark;
      headline = 'Documents rejected';
      subline = 'Re-upload required.';
    } else if (status == 'not_started') {
      if (dueAt == null) return const SizedBox.shrink();
      final daysRemaining = dueAt.difference(DateTime.now()).inDays;
      if (daysRemaining > 0) {
        tint = Colors.amber.shade700;
        icon = FontAwesomeIcons.hourglassHalf;
        headline = '$daysRemaining day${daysRemaining == 1 ? '' : 's'} remaining';
        subline = 'Staff has yet to upload verification documents.';
      } else {
        tint = Colors.red;
        icon = FontAwesomeIcons.triangleExclamation;
        headline = 'Verification overdue';
        subline = 'Staff has yet to upload verification documents.';
        showInfoIcon = true;
      }
      showExtendButton = true;
    } else {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(bottom: rSize(context, 24)),
      child: Container(
        padding: EdgeInsets.all(rSize(context, 20)),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 16, color: tint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              headline,
                              style: TextStyle(
                                fontSize: rFontSize(context, 16),
                                fontWeight: FontWeight.bold,
                                color: tint,
                              ),
                            ),
                          ),
                          if (showInfoIcon) ...[
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: _showOverdueInfo,
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  Icons.info_outline_rounded,
                                  size: 16,
                                  color: _subtext,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subline,
                        style: TextStyle(
                          fontSize: rFontSize(context, 12),
                          color: _subtext,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (showExtendButton) ...[
              SizedBox(height: rSize(context, 16)),
              RoleGuard(
                minTier: 5,
                fallback: const SizedBox.shrink(),
                child: _buildExtendButton(member),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildExtendButton(BusinessMemberData member) {
    final capReached = member.verificationExtensionsUsed >= 2;
    final button = AppButton(
      text: 'Extend deadline',
      size: AppButtonSize.small,
      variant: AppButtonVariant.secondary,
      onPressed: capReached ? null : () => _showExtendDialog(member),
    );
    if (!capReached) return button;
    return Tooltip(
      message: 'Maximum extensions reached for this staff',
      child: button,
    );
  }

  void _showOverdueInfo() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'About verification',
          style: TextStyle(color: _text, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Unverified staff are not yet identity-confirmed. They can still use the app.',
          style: TextStyle(color: _subtext),
        ),
        actions: [
          AppButton(
            text: 'Got it',
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  Future<void> _showExtendDialog(BusinessMemberData member) async {
    final customCtrl = TextEditingController();
    final reasonCtrl = TextEditingController();
    _ExtendDeadlineChoice choice = _ExtendDeadlineChoice.sevenDays;
    bool busy = false;
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          int? resolveExtraDays() {
            switch (choice) {
              case _ExtendDeadlineChoice.sevenDays:
                return 7;
              case _ExtendDeadlineChoice.fourteenDays:
                return 14;
              case _ExtendDeadlineChoice.custom:
                final parsed = int.tryParse(customCtrl.text.trim());
                if (parsed == null || parsed < 1 || parsed > 60) return null;
                return parsed;
            }
          }

          Future<void> submit() async {
            final days = resolveExtraDays();
            final reason = reasonCtrl.text.trim();
            if (days == null) {
              setStateDialog(() =>
                  errorText = 'Enter a number of days between 1 and 60.');
              return;
            }
            if (reason.isEmpty) {
              setStateDialog(
                  () => errorText = 'Add a short reason for the extension.');
              return;
            }
            setStateDialog(() {
              busy = true;
              errorText = null;
            });
            final api = ref.read(inviteApiServiceProvider);
            final result = await api.extendVerification(
              membershipId: member.id,
              extraDays: days,
              reason: reason,
            );
            if (!ctx.mounted) return;
            Navigator.pop(ctx);
            if (!mounted) return;
            if (result is InviteApiErr<Map<String, dynamic>>) {
              AppNotification.showError(context, result.message);
              return;
            }
            AppNotification.showSuccess(
              context,
              'Deadline extended by $days day${days == 1 ? '' : 's'}.',
            );
          }

          return AlertDialog(
            backgroundColor: _surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            title: Text(
              'Extend verification deadline',
              style: TextStyle(color: _text, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      _extendChoiceChip(
                        _ExtendDeadlineChoice.sevenDays,
                        '+7 days',
                        choice,
                        (c) => setStateDialog(() => choice = c),
                      ),
                      _extendChoiceChip(
                        _ExtendDeadlineChoice.fourteenDays,
                        '+14 days',
                        choice,
                        (c) => setStateDialog(() => choice = c),
                      ),
                      _extendChoiceChip(
                        _ExtendDeadlineChoice.custom,
                        'Custom',
                        choice,
                        (c) => setStateDialog(() => choice = c),
                      ),
                    ],
                  ),
                  if (choice == _ExtendDeadlineChoice.custom) ...[
                    const SizedBox(height: 12),
                    AppInput(
                      controller: customCtrl,
                      labelText: 'Days (1–60)',
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ],
                  const SizedBox(height: 16),
                  AppInput(
                    controller: reasonCtrl,
                    labelText: 'Reason',
                    hintText: 'Why are you extending?',
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorText!,
                      style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              AppButton(
                text: 'Cancel',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.small,
                onPressed: busy ? null : () => Navigator.pop(ctx),
              ),
              AppButton(
                text: busy ? 'Extending…' : 'Extend',
                size: AppButtonSize.small,
                onPressed: busy ? null : submit,
              ),
            ],
          );
        },
      ),
    );

    customCtrl.dispose();
    reasonCtrl.dispose();
  }

  Widget _extendChoiceChip(
    _ExtendDeadlineChoice value,
    String label,
    _ExtendDeadlineChoice current,
    ValueChanged<_ExtendDeadlineChoice> onSelect,
  ) {
    return ChoiceChip(
      label: Text(label),
      selected: value == current,
      onSelected: (_) => onSelect(value),
    );
  }

  Widget _buildPerformanceMetrics(bool isWide) {
    final orders = _staffOrders;
    final completed = orders.where((o) => o.status == 'completed').toList();
    final totalSales = completed.fold<double>(
      0.0,
      (sum, o) => sum + (o.netAmountKobo / 100.0),
    );

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: isWide ? 3 : 2,
      mainAxisSpacing: rSize(context, 12),
      crossAxisSpacing: rSize(context, 12),
      childAspectRatio: 1.2,
      children: [
        _statCard(
          'Total Orders',
          orders.length.toString(),
          FontAwesomeIcons.receipt,
          Theme.of(context).colorScheme.primary,
        ),
        _statCard(
          'Completed',
          completed.length.toString(),
          FontAwesomeIcons.checkDouble,
          AppColors.success,
        ),
        _statCard(
          'Sales Volume',
          formatCurrency(totalSales),
          FontAwesomeIcons.nairaSign,
          const Color(0xFFA855F7),
        ), // Fixed later if needed
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: EdgeInsets.all(rSize(context, 16)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: color, size: rSize(context, 18)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: rFontSize(context, 18),
                  fontWeight: FontWeight.w900,
                  color: _text,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: rFontSize(context, 11),
                  color: _subtext,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSystemInfo() {
    return Container(
      padding: EdgeInsets.all(rSize(context, 20)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'System Details',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: rFontSize(context, 14),
              color: _text,
            ),
          ),
          SizedBox(height: rSize(context, 16)),
          _infoRow(
            'Role Tier',
            'Tier ${widget.user.roleTier}',
            FontAwesomeIcons.shieldHalved,
          ),
          _infoRow(
            'Biometrics',
            widget.user.biometricEnabled ? 'Enabled' : 'Disabled',
            FontAwesomeIcons.fingerprint,
          ),
          _infoRow(
            'Email',
            widget.user.email ?? 'Not provided',
            FontAwesomeIcons.envelope,
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, IconData icon) {
    return Padding(
      padding: EdgeInsets.only(bottom: rSize(context, 12)),
      child: Row(
        children: [
          Icon(icon, size: 12, color: _subtext),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(color: _subtext, fontSize: rFontSize(context, 13)),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: _text,
              fontWeight: FontWeight.bold,
              fontSize: rFontSize(context, 13),
            ),
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

  Color? _parseColor(String hex) {
    try {
      final cleaned = hex.replaceFirst('#', '');
      return Color(int.parse('FF$cleaned', radix: 16));
    } catch (_) {
      return null;
    }
  }
}

enum _ExtendDeadlineChoice { sevenDays, fourteenDays, custom }
