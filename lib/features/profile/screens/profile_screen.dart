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
import 'package:reebaplus_pos/shared/models/order_status.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/settings/delete_business_screen.dart';
import 'package:reebaplus_pos/features/profile/widgets/edit_profile_sheet.dart';
import 'package:reebaplus_pos/features/profile/widgets/profile_ui.dart';
import 'package:reebaplus_pos/features/profile/self_resign.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/sync/widgets/resolve_unsynced_data_dialog.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
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
      _ordersSub =
          (db.select(
            db.orders,
          )..where((t) => t.staffId.equals(user.id))).watch().listen((data) {
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
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    final user = ref.watch(authProvider).currentUser;
    if (user == null) {
      return const SharedScaffold(
        activeRoute: 'profile',
        body: Center(child: Text('No user logged in')),
      );
    }

    final storeName =
        _stores.where((w) => w.id == user.storeId).firstOrNull?.name ??
        'Unassigned';

    // Real role (master plan §8.2) — null until the membership + role rows are
    // local (returning devices already have them; a fresh device gets them via
    // the post-login pull). Falls back to a neutral label while resolving.
    final role = ref.watch(userRoleProvider(user.id));
    final roleName = role?.name ?? 'Member';
    final roleColor = roleTagColor(role?.slug);

    // §32: PRO (paid) / FREE TRIAL pill shown in the header when subscribed.
    final subAccess = ref.watch(currentBusinessSubscriptionProvider);

    final appBar = AppBar(
      backgroundColor: _surface,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_new_rounded, color: _text, size: 20),
        onPressed: () => Navigator.pop(context),
      ),
      title: AppBarHeader(
        icon: FontAwesomeIcons.user.data,
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
        padding: EdgeInsets.all(
          context.getRSize(20),
        ).copyWith(bottom: context.getRSize(20) + context.deviceBottomPadding),
        children: [
          ProfileHeaderCard(
            name: user.name,
            avatarColorHex: user.avatarColor,
            roleLabel: roleName,
            roleColor: roleColor,
            pills: [
              if (subAccess.badgeLabel != null)
                ProfilePill(
                  icon: subAccess == SubscriptionAccess.active
                      ? FontAwesomeIcons.crown.data
                      : FontAwesomeIcons.solidClock.data,
                  label: subAccess.badgeLabel!,
                  color: subAccess == SubscriptionAccess.active
                      ? Theme.of(context).colorScheme.primary
                      : const Color(0xFFF59E0B),
                ),
              ProfilePill(icon: FontAwesomeIcons.store.data, label: storeName),
            ],
          ),
          SizedBox(height: context.getRSize(24)),
          ProfileStatGrid(stats: _buildStats()),
          SizedBox(height: context.getRSize(24)),
          ProfileInfoCard(
            title: 'Account Details',
            rows: [
              ProfileInfoRow(
                icon: FontAwesomeIcons.store.data,
                label: 'Store',
                value: storeName,
              ),
              ProfileInfoRow(
                icon: FontAwesomeIcons.envelope.data,
                label: 'Email',
                value: user.email ?? 'Not provided',
              ),
              ProfileInfoRow(
                icon: FontAwesomeIcons.fingerprint.data,
                label: 'Biometrics',
                value: user.biometricEnabled ? 'Enabled' : 'Disabled',
              ),
              ProfileInfoRow(
                icon: FontAwesomeIcons.calendarDay.data,
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
            icon: FontAwesomeIcons.penToSquare.data,
            onPressed: () {
              final u = ref.read(authProvider).currentUser;
              if (u == null) return;
              _openEditProfileSheet(u);
            },
          ),
          // Offboarding (#117). The OWNER has no resign path — their exit is
          // Delete Business (the existing danger-zone flow). Every other staff
          // member can leave & delete their own account (no permission needed).
          // Both hidden while the role is still resolving (hide-don't-block).
          if (isOwnerRole(role)) ...[
            SizedBox(height: context.getRSize(16)),
            AppButton(
              text: 'Delete Business',
              variant: AppButtonVariant.danger,
              icon: FontAwesomeIcons.triangleExclamation.data,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DeleteBusinessScreen(),
                ),
              ),
            ),
          ] else if (canSelfResign(role)) ...[
            SizedBox(height: context.getRSize(16)),
            AppButton(
              text: 'Leave / delete my account',
              variant: AppButtonVariant.danger,
              icon: FontAwesomeIcons.rightFromBracket.data,
              onPressed: _confirmAndResign,
            ),
          ],
          SizedBox(height: context.getRSize(100)),
        ],
      ),
    );
  }

  List<ProfileStat> _buildStats() {
    final orders = _staffOrders;
    final completed = orders.where((o) => o.status == 'completed').toList();
    // Sales volume is recognized at checkout ('pending'), not at the ceremonial
    // Confirm ('completed'). Count any non-reversed sale; the "Completed" stat
    // below stays a true lifecycle count.
    final totalSales = orders
        .where((o) => orderCountsAsSale(o.status))
        .fold<double>(0.0, (sum, o) => sum + (o.netAmountKobo / 100.0));
    return [
      ProfileStat(
        label: 'Total Orders',
        value: orders.length.toString(),
        icon: FontAwesomeIcons.receipt.data,
        color: Theme.of(context).colorScheme.primary,
      ),
      ProfileStat(
        label: 'Completed',
        value: completed.length.toString(),
        icon: FontAwesomeIcons.checkDouble.data,
        color: AppColors.success,
      ),
      ProfileStat(
        label: 'Sales Volume',
        value: formatCurrency(totalSales),
        icon: FontAwesomeIcons.nairaSign.data,
        color: const Color(0xFFA855F7),
      ),
    ];
  }

  /// #117 self-resign. Confirms, then hands off to
  /// [AuthService.resignOwnMembership] (server-authoritative detach + free the
  /// email). The device side reuses the sole-user wipe gate, so the two-tier
  /// unsynced-data outcome is surfaced exactly as the drawer logout does —
  /// retryable rows → an error ("connect and sync first"); orphans only → the
  /// Resolve-unsynced-data flow (here with `isResign: true`, whose terminal also
  /// completes the server detach). On success, main.dart routes to Welcome (sole
  /// member) or the Who's Working picker (shared till).
  Future<void> _confirmAndResign() async {
    final auth = ref.read(authProvider);
    final db = ref.read(databaseProvider);
    final user = auth.currentUser;
    if (user == null) return;

    // Sole member on this device → the resign wipes local data (as a sole-user
    // logout); otherwise only this user is removed from the shared till. Used to
    // word the confirmation honestly.
    final deviceStaffCount =
        await db.userBusinessesDao.countDeviceStaffForBusiness(user.businessId);
    final isSoleUser = deviceStaffCount <= 1;
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave and delete your account?'),
        content: Text(
          isSoleUser
              ? 'You will be signed out and removed from this business. Your '
                  'email is freed so you can start a new business with it '
                  'later.\n\nYou are the only user on this device, so all local '
                  'data will be erased. You can re-download it after signing in '
                  'to another business.'
              : 'You will be signed out and removed from this business. Your '
                  'email is freed so you can start a new business with it '
                  'later.\n\nOther staff on this device keep their data and '
                  'stay signed in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await auth.resignOwnMembership();
    } on LogoutBlockedByUnsyncedDataException catch (e) {
      // Orphans only (sole member): route to export → typed-confirm discard,
      // whose terminal (isResign) also completes the server-side detach.
      if (mounted) {
        await showResolveUnsyncedDataDialog(
          context,
          ref,
          pendingCount: e.pendingCount,
          orphanCount: e.orphanCount,
          isResign: true,
        );
      }
    } on LogoutWipeException catch (e) {
      if (mounted) AppNotification.showError(context, e.message);
    } on StaffResignException catch (e) {
      if (mounted) AppNotification.showError(context, e.message);
    } catch (e) {
      if (mounted) {
        AppNotification.showError(
          context,
          'An unexpected error occurred while leaving your account.',
        );
      }
    }
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
