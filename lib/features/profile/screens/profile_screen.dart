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
import 'package:reebaplus_pos/features/profile/widgets/edit_profile_sheet.dart';
import 'package:reebaplus_pos/features/profile/widgets/profile_ui.dart';
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

    final appBar = AppBar(
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
    );

    if (!_contentReady) {
      return SharedScaffold(
        activeRoute: 'profile',
        backgroundColor: _bg,
        appBar: appBar,
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
      appBar: appBar,
      body: ListView(
        padding: EdgeInsets.all(context.getRSize(20)).copyWith(
          bottom: context.getRSize(20) + context.deviceBottomInset,
        ),
        children: [
          ProfileHeaderCard(
            name: user.name,
            avatarColorHex: user.avatarColor,
            roleLabel: roleName,
            roleColor: roleColor,
            pills: [
              ProfilePill(icon: FontAwesomeIcons.store, label: storeName),
            ],
          ),
          SizedBox(height: context.getRSize(24)),
          ProfileStatGrid(stats: _buildStats()),
          SizedBox(height: context.getRSize(24)),
          ProfileInfoCard(
            title: 'Account Details',
            rows: [
              ProfileInfoRow(
                icon: FontAwesomeIcons.store,
                label: 'Store',
                value: storeName,
              ),
              ProfileInfoRow(
                icon: FontAwesomeIcons.envelope,
                label: 'Email',
                value: user.email ?? 'Not provided',
              ),
              ProfileInfoRow(
                icon: FontAwesomeIcons.fingerprint,
                label: 'Biometrics',
                value: user.biometricEnabled ? 'Enabled' : 'Disabled',
              ),
              ProfileInfoRow(
                icon: FontAwesomeIcons.calendarDay,
                label: 'Member Since',
                value:
                    '${user.createdAt.day}/${user.createdAt.month}/${user.createdAt.year}',
              ),
            ],
          ),
          SizedBox(height: context.getRSize(24)),
          AppButton(
            text: 'Edit Profile',
            variant: AppButtonVariant.outline,
            icon: FontAwesomeIcons.penToSquare,
            onPressed: () {
              final u = ref.read(authProvider).currentUser;
              if (u == null) return;
              _openEditProfileSheet(u);
            },
          ),
          SizedBox(height: context.getRSize(100)),
        ],
      ),
    );
  }

  List<ProfileStat> _buildStats() {
    final orders = _staffOrders;
    final completed = orders.where((o) => o.status == 'completed').toList();
    final totalSales = completed.fold<double>(
      0.0,
      (sum, o) => sum + (o.netAmountKobo / 100.0),
    );
    return [
      ProfileStat(
        label: 'Total Orders',
        value: orders.length.toString(),
        icon: FontAwesomeIcons.receipt,
        color: Theme.of(context).colorScheme.primary,
      ),
      ProfileStat(
        label: 'Completed',
        value: completed.length.toString(),
        icon: FontAwesomeIcons.checkDouble,
        color: AppColors.success,
      ),
      ProfileStat(
        label: 'Sales Volume',
        value: formatCurrency(totalSales),
        icon: FontAwesomeIcons.nairaSign,
        color: const Color(0xFFA855F7),
      ),
    ];
  }

  /// Self-service edit of the logged-in user's own name + avatar colour.
  /// No role gate — a user can always edit their own profile.
  void _openEditProfileSheet(UserData user) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EditProfileSheet(user: user, parentRef: ref),
    );
  }
}
