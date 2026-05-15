import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_constants.dart';
import 'package:reebaplus_pos/shared/utils/avatar_helpers.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  List<OrderData> _staffOrders = [];
  List<WarehouseData> _warehouses = [];
  StreamSubscription<List<OrderData>>? _ordersSub;
  bool _contentReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final user = ref.read(authProvider).currentUser;
      if (user == null) return;

      final db = ref.read(databaseProvider);

      // Load warehouses once
      db.select(db.warehouses).get().then((list) {
        if (mounted) setState(() => _warehouses = list);
      });

      // Watch orders for current user
      _ordersSub = (db.select(db.orders)
            ..where((t) => t.staffId.equals(user.id)))
          .watch()
          .listen((data) {
        if (mounted) setState(() => _staffOrders = data);
      });

      setState(() => _contentReady = true);
    });
  }

  @override
  void dispose() {
    _ordersSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).currentUser;
    if (user == null) {
      return const SharedScaffold(
        activeRoute: 'profile',
        body: Center(child: Text('No user logged in')),
      );
    }

    final avatarColor =
        parseHexColor(user.avatarColor) ?? Theme.of(context).colorScheme.primary;
    final warehouseName = _warehouses
            .where((w) => w.id == user.warehouseId)
            .firstOrNull
            ?.name ??
        'Unassigned';

    if (!_contentReady) {
      return SharedScaffold(
        activeRoute: 'profile',
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _surface,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: _text, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: AppBarHeader(
            icon: FontAwesomeIcons.user,
            title: user.name,
            subtitle: user.role.toUpperCase(),
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
      activeRoute: 'profile',
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: _text, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: AppBarHeader(
          icon: FontAwesomeIcons.user,
          title: user.name,
          subtitle: user.role.toUpperCase(),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 600;
          return ListView(
            padding: EdgeInsets.all(context.getRSize(20)),
            children: [
              _buildProfileHeader(user, avatarColor, warehouseName),
              SizedBox(height: context.getRSize(24)),
              _buildPerformanceMetrics(isWide),
              SizedBox(height: context.getRSize(24)),
              _buildSystemInfo(user, warehouseName),
              SizedBox(height: context.getRSize(24)),
              _buildActions(),
              SizedBox(height: context.getRSize(100)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildProfileHeader(
      UserData user, Color color, String warehouse) {
    return Container(
      padding: EdgeInsets.all(context.getRSize(24)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          Container(
            width: context.getRSize(80),
            height: context.getRSize(80),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border:
                  Border.all(color: color.withValues(alpha: 0.3), width: 3),
            ),
            child: Center(
              child: Text(
                avatarInitials(user.name),
                style: TextStyle(
                  color: color,
                  fontSize: context.getRFontSize(24),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          Text(
            user.name,
            style: TextStyle(
              fontSize: context.getRFontSize(20),
              fontWeight: FontWeight.w900,
              color: _text,
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          _buildRoleTag(user.role),
          SizedBox(height: context.getRSize(8)),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(10),
              vertical: context.getRSize(4),
            ),
            decoration: BoxDecoration(
              color: _subtext.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FontAwesomeIcons.warehouse,
                    size: context.getRSize(10), color: _subtext),
                SizedBox(width: context.getRSize(6)),
                Text(
                  warehouse,
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    fontWeight: FontWeight.w600,
                    color: _subtext,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleTag(String role) {
    final color = _roleColor(role);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        role.toUpperCase(),
        style: TextStyle(
          fontSize: context.getRFontSize(11),
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  // Delegates to staff_constants so role colors stay in one source.
  // The previous parallel switch had drifted (different hex values + a
  // bogus 'stock keeper' key with a space) — see role-refactor briefing.
  Color _roleColor(String role) => roleFor(role).color;

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
      mainAxisSpacing: context.getRSize(12),
      crossAxisSpacing: context.getRSize(12),
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
        ),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: color, size: context.getRSize(18)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: context.getRFontSize(18),
                  fontWeight: FontWeight.w900,
                  color: _text,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: context.getRFontSize(11),
                  color: _subtext,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSystemInfo(UserData user, String warehouse) {
    return Container(
      padding: EdgeInsets.all(context.getRSize(20)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Account Details',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: context.getRFontSize(14),
              color: _text,
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          _infoRow(
            'Role Tier',
            'Tier ${user.roleTier}',
            FontAwesomeIcons.shieldHalved,
          ),
          _infoRow(
            'Warehouse',
            warehouse,
            FontAwesomeIcons.warehouse,
          ),
          _infoRow(
            'Email',
            user.email ?? 'Not provided',
            FontAwesomeIcons.envelope,
          ),
          _infoRow(
            'Biometrics',
            user.biometricEnabled ? 'Enabled' : 'Disabled',
            FontAwesomeIcons.fingerprint,
          ),
          _infoRow(
            'Member Since',
            '${user.createdAt.day}/${user.createdAt.month}/${user.createdAt.year}',
            FontAwesomeIcons.calendarDay,
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, IconData icon) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(12)),
      child: Row(
        children: [
          Icon(icon, size: 12, color: _subtext),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
                color: _subtext, fontSize: context.getRFontSize(13)),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                color: _text,
                fontWeight: FontWeight.bold,
                fontSize: context.getRFontSize(13),
              ),
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Row(
      children: [
        Expanded(
          child: AppButton(
            text: 'Edit Profile',
            variant: AppButtonVariant.outline,
            icon: FontAwesomeIcons.penToSquare,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ),
      ],
    );
  }
}
