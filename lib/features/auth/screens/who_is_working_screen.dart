import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/screens/login_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';

/// The shared-till "Who's working?" picker (master plan §8). Shown all day
/// when staff switch shifts or return after auto-lock — distinct from Login,
/// which is for a fresh device or full logout.
///
/// Renders BEFORE sign-in, so the session has no current business. It resolves
/// the business id explicitly (device user → their business, with a single-
/// local-business fallback) and reads staff via the unscoped
/// [activeStaffProvider]; the session-scoped providers can't be used here.
class WhoIsWorkingScreen extends ConsumerStatefulWidget {
  const WhoIsWorkingScreen({super.key});

  @override
  ConsumerState<WhoIsWorkingScreen> createState() =>
      _WhoIsWorkingScreenState();
}

class _WhoIsWorkingScreenState extends ConsumerState<WhoIsWorkingScreen> {
  String? _businessId;
  UserData? _deviceUser;
  bool _resolving = true;
  // Guards the single pushReplacement in the 0/1-staff shortcut so a stream
  // re-emit during the post-frame callback can't fire it twice.
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _resolveBusiness();
  }

  Future<void> _resolveBusiness() async {
    final auth = ref.read(authProvider);
    final db = ref.read(databaseProvider);

    String? businessId;
    UserData? deviceUser;

    final userId = await auth.getDeviceUserId();
    if (userId != null) {
      deviceUser = await db.storesDao.getUserById(userId);
      businessId = deviceUser?.businessId;
    }

    // Defensive fallback when the device user didn't resolve a business: only
    // auto-pick when there's exactly ONE local business — never guess between
    // multiple tenants. With 0 or >1, leave businessId null so _buildBody falls
    // back to the PIN/email flow.
    if (businessId == null) {
      final businesses = await db.select(db.businesses).get();
      if (businesses.length == 1) businessId = businesses.first.id;
    }

    if (!mounted) return;
    setState(() {
      _businessId = businessId;
      _deviceUser = deviceUser;
      _resolving = false;
    });
  }

  /// Replaces the picker with the PIN screen for [presetUser] (used by the
  /// 0-/1-staff shortcut, §8.3). Post-frame + guarded so it never runs during
  /// build or more than once.
  void _replaceWithPin(UserData? presetUser) {
    if (_navigated) return;
    _navigated = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => LoginScreen(presetUser: presetUser),
        ),
      );
    });
  }

  /// Runs [action] once, after the current frame — used by the single-staff
  /// shortcut's no-PIN (OTP) path, which (like [_replaceWithPin]) must not
  /// navigate during build. Shares the [_navigated] guard.
  void _shortcutTo(VoidCallback action) {
    if (_navigated) return;
    _navigated = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action();
    });
  }

  Future<void> _onTapStaff(WhoIsWorkingEntry entry) async {
    final user = entry.user;
    // Has a PIN → straight to the PIN screen (§8.4).
    if (user.pinHash != null) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LoginScreen(presetUser: user)),
      );
      return;
    }

    // No PIN yet → verify by email OTP so they can set one.
    final email = user.email;
    if (email == null || email.isEmpty) {
      AppNotification.showError(
        context,
        'No email on file for ${user.name}. Ask your CEO to update it.',
      );
      return;
    }
    final error = await ref.read(authProvider).sendOtp(email);
    if (!mounted) return;
    if (error != null) {
      AppNotification.showError(context, error);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OtpVerificationScreen(user: user, email: email),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: adBg,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _buildBody(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_resolving) {
      return const _BrandedFade(key: ValueKey('resolving'));
    }
    final businessId = _businessId;
    if (businessId == null) {
      // Nothing to pick from — fall back to the PIN screen.
      _replaceWithPin(_deviceUser);
      return const _BrandedFade(key: ValueKey('no-business'));
    }

    final staffAsync = ref.watch(activeStaffProvider(businessId));
    return staffAsync.when(
      loading: () => const _BrandedFade(key: ValueKey('loading')),
      error: (_, __) {
        _replaceWithPin(_deviceUser);
        return const _BrandedFade(key: ValueKey('error'));
      },
      data: (staff) {
        // §8.3: 0 or 1 staff → skip the picker. Mirror _onTapStaff so a single
        // staff member without a device PIN verifies by OTP rather than being
        // dropped on the PIN screen.
        if (staff.length <= 1) {
          final entry = staff.isEmpty ? null : staff.first;
          if (entry != null && entry.user.pinHash == null) {
            _shortcutTo(() => _onTapStaff(entry));
          } else {
            _replaceWithPin(entry?.user ?? _deviceUser);
          }
          return const _BrandedFade(key: ValueKey('shortcut'));
        }
        // Arrange by role (CEO → Manager → Cashier → Stock keeper), then name
        // — consistent with the Staff Management list (§9.2).
        final ordered = [...staff]..sort((a, b) {
          final r = roleRank(a.role?.slug).compareTo(roleRank(b.role?.slug));
          return r != 0 ? r : a.user.name.compareTo(b.user.name);
        });
        return _PickerList(
          key: const ValueKey('picker'),
          businessId: businessId,
          staff: ordered,
          onTap: _onTapStaff,
        );
      },
    );
  }
}

/// Header (business name + date) + scrollable staff cards (§8.1).
class _PickerList extends ConsumerWidget {
  final String businessId;
  final List<WhoIsWorkingEntry> staff;
  final ValueChanged<WhoIsWorkingEntry> onTap;

  const _PickerList({
    super.key,
    required this.businessId,
    required this.staff,
    required this.onTap,
  });

  String _businessName(WidgetRef ref) {
    final businesses = ref.watch(localBusinessesProvider).valueOrNull ?? const [];
    for (final b in businesses) {
      if (b.id == businessId) return b.name;
    }
    return businesses.isNotEmpty ? businesses.first.name : '';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dateStr = DateFormat('EEEE, MMMM d').format(DateTime.now());
    final businessName = _businessName(ref);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: context.rPaddingSymmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (businessName.isNotEmpty)
                Text(
                  businessName,
                  style: TextStyle(
                    color: adTextPrimary.withValues(alpha: 0.7),
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              SizedBox(height: context.getRSize(2)),
              Text(
                dateStr,
                style: TextStyle(
                  color: adTextPrimary.withValues(alpha: 0.5),
                  fontSize: context.getRFontSize(12),
                ),
              ),
              SizedBox(height: context.getRSize(16)),
              Text(
                "Who's working?",
                style: TextStyle(
                  color: adTextPrimary,
                  fontSize: context.getRFontSize(26),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.only(bottom: context.getRSize(24)),
            itemCount: staff.length,
            itemBuilder: (context, i) => _StaffPickerCard(
              entry: staff[i],
              onTap: () => onTap(staff[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// A tappable staff card (§8.2): avatar initials over the user's avatar
/// colour, name, and role colour tag. No "active now" dot (deferred).
class _StaffPickerCard extends StatelessWidget {
  final WhoIsWorkingEntry entry;
  final VoidCallback onTap;

  const _StaffPickerCard({required this.entry, required this.onTap});

  Color _avatarColor() {
    final hex = entry.user.avatarColor.replaceFirst('#', '');
    final value = int.tryParse('FF$hex', radix: 16);
    return value != null ? Color(value) : const Color(0xFF3B82F6);
  }

  @override
  Widget build(BuildContext context) {
    final role = entry.role;
    final tagColor = roleTagColor(role?.slug);
    final name = entry.user.name;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(6),
      ),
      child: Material(
        color: adSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: adBorder),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(14)),
            child: Row(
              children: [
                CircleAvatar(
                  radius: context.getRSize(24),
                  backgroundColor: _avatarColor(),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(18),
                    ),
                  ),
                ),
                SizedBox(width: context.getRSize(14)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          color: adTextPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: context.getRFontSize(16),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: context.getRSize(6)),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: tagColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          role?.name ?? 'Unknown',
                          style: TextStyle(
                            color: tagColor,
                            fontSize: context.getRFontSize(11),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: adTextPrimary.withValues(alpha: 0.4),
                  size: context.getRSize(20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Subtle branded fade shown while resolving / loading (§30.7 — no spinners).
class _BrandedFade extends StatelessWidget {
  const _BrandedFade({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeIn,
        builder: (context, opacity, child) =>
            Opacity(opacity: opacity, child: child),
        child: Image.asset(
          'assets/images/reebaplus_logo.png',
          height: context.getRSize(60),
        ),
      ),
    );
  }
}
