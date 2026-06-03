import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
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
  List<StoreData> _stores = [];
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

      // Load stores once
      db.storesDao.getActiveStores().then((list) {
        if (mounted) setState(() => _stores = list);
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
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    final user = ref.watch(authProvider).currentUser;
    if (user == null) {
      return const SharedScaffold(
        activeRoute: 'profile',
        body: Center(child: Text('No user logged in')),
      );
    }

    final avatarColor =
        parseHexColor(user.avatarColor) ?? Theme.of(context).colorScheme.primary;
    final storeName = _stores
            .where((w) => w.id == user.storeId)
            .firstOrNull
            ?.name ??
        'Unassigned';

    // Real role (master plan §8.2) — null until the membership + role rows are
    // local (returning devices already have them; a fresh device gets them via
    // the post-login pull). Falls back to a neutral label while resolving.
    final role = ref.watch(userRoleProvider(user.id));
    final roleName = role?.name ?? 'Member';
    final roleColor = roleTagColor(role?.slug);

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
            subtitle: roleName.toUpperCase(),
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
          subtitle: roleName.toUpperCase(),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 600;
          return ListView(
            padding: EdgeInsets.all(context.getRSize(20)).copyWith(
              bottom: context.getRSize(20) + context.deviceBottomInset,
            ),
            children: [
              _buildProfileHeader(
                  user, avatarColor, storeName, roleName, roleColor),
              SizedBox(height: context.getRSize(24)),
              _buildPerformanceMetrics(isWide),
              SizedBox(height: context.getRSize(24)),
              _buildSystemInfo(user, storeName),
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
      UserData user, Color color, String store, String roleName,
      Color roleColor) {
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
          _buildRoleTag(roleName, roleColor),
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
                Icon(FontAwesomeIcons.store,
                    size: context.getRSize(10), color: _subtext),
                SizedBox(width: context.getRSize(6)),
                Text(
                  store,
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

  Widget _buildRoleTag(String role, Color color) {
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

  Widget _buildSystemInfo(UserData user, String store) {
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
            'Store',
            store,
            FontAwesomeIcons.store,
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
              final user = ref.read(authProvider).currentUser;
              if (user == null) return;
              _openEditProfileSheet(user);
            },
          ),
        ),
      ],
    );
  }

  /// Self-service edit of the logged-in user's own name + avatar colour.
  /// No role gate — a user can always edit their own profile.
  void _openEditProfileSheet(UserData user) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditProfileSheet(user: user, parentRef: ref),
    );
  }
}

/// Bottom-sheet body for editing the current user's name + avatar colour.
/// Local state (name field + swatch selection) lives here so taps update
/// live without rebuilding the whole profile screen.
class _EditProfileSheet extends StatefulWidget {
  final UserData user;
  final WidgetRef parentRef;
  const _EditProfileSheet({required this.user, required this.parentRef});

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  static const _swatches = [
    '#3B82F6',
    '#22C55E',
    '#F59E0B',
    '#EF4444',
    '#A855F7',
    '#EC4899',
    '#14B8A6',
    '#6B7280',
  ];

  late final TextEditingController _nameController;
  late String _selectedHex;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.user.name);
    _selectedHex = _swatches.contains(widget.user.avatarColor)
        ? widget.user.avatarColor
        : _swatches.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.length < 2) {
      AppNotification.showError(context, 'Enter at least 2 characters.');
      return;
    }

    setState(() => _saving = true);
    final db = widget.parentRef.read(databaseProvider);
    try {
      await db.storesDao.updateUserProfile(
        id: widget.user.id,
        name: name,
        avatarColor: _selectedHex,
      );
      await widget.parentRef.read(authProvider).refreshCurrentUser();
      await db.activityLogDao.log(
        action: 'settings.profile.update',
        description: 'Updated profile (name, avatar)',
        staffId: db.currentUserId,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      AppNotification.showSuccess(context, 'Profile updated.');
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(context, 'Couldn\'t update profile.');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        24 + context.deviceBottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: t.colorScheme.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Edit Profile',
            style: TextStyle(
              fontSize: context.getRFontSize(18),
              fontWeight: FontWeight.bold,
              color: t.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Name',
              prefixIcon: Icons.person_rounded,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Avatar colour',
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w600,
              color: t.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final hex in _swatches)
                GestureDetector(
                  onTap: () => setState(() => _selectedHex = hex),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: parseHexColor(hex),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _selectedHex == hex
                            ? t.colorScheme.onSurface
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: _selectedHex == hex
                        ? const Icon(Icons.check_rounded,
                            color: Colors.white, size: 20)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _saving ? null : _save,
            child: Opacity(
              opacity: _saving ? 0.6 : 1,
              child: Container(
                height: 54,
                alignment: Alignment.center,
                decoration: AppDecorations.primaryGradient(context, radius: 14),
                child: const Text(
                  'Save changes',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
