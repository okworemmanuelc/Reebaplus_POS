import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:local_auth/local_auth.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/features/profile/screens/profile_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _autoLockSeconds = 0; // default Never — auto-lock is opt-in
  bool _biometricsEnabled = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final dao = ref.read(databaseProvider).settingsDao;
    final intervalStr = await dao.get('auto_lock_interval_seconds');
    final bioStr = await dao.get('biometrics_enabled');

    if (mounted) {
      setState(() {
        _autoLockSeconds = int.tryParse(intervalStr ?? '') ?? 0;
        _biometricsEnabled = bioStr == 'true';
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleBiometrics(bool enable) async {
    final dao = ref.read(databaseProvider).settingsDao;
    if (enable) {
      final auth = LocalAuthentication();
      try {
        final available =
            await auth.canCheckBiometrics || await auth.isDeviceSupported();
        if (!available) {
          if (mounted) {
            AppNotification.showError(
              context,
              'Biometrics not supported on this device.',
            );
          }
          return;
        }

        final authenticated = await auth.authenticate(
          localizedReason: 'Please authenticate to enable biometrics',
          options: const AuthenticationOptions(
            stickyAuth: false,
            biometricOnly: false,
          ),
        );

        if (authenticated) {
          await dao.set('biometrics_enabled', 'true');
          if (mounted) setState(() => _biometricsEnabled = true);
        }
      } catch (e) {
        if (mounted) {
          AppNotification.showError(context, 'Failed to enable biometrics.');
        }
      }
    } else {
      await dao.set('biometrics_enabled', 'false');
      if (mounted) setState(() => _biometricsEnabled = false);
    }
  }

  Future<void> _saveAutoLock(int seconds) async {
    final dao = ref.read(databaseProvider).settingsDao;
    await dao.set('auto_lock_interval_seconds', seconds.toString());
    if (mounted) {
      setState(() {
        _autoLockSeconds = seconds;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isDark = t.brightness == Brightness.dark;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: t.scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text('Settings'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Account',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: t.colorScheme.primary,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          _buildSettingCard(
            context: context,
            icon: FontAwesomeIcons.userGear,
            title: 'Profile',
            subtitle: 'Manage your account details',
            trailing: Icon(
              Icons.chevron_right,
              color: t.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
            isDark: isDark,
          ),
          const SizedBox(height: 32),
          Text(
            'Security',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: t.colorScheme.primary,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          _buildSettingCard(
            context: context,
            icon: FontAwesomeIcons.lock,
            title: 'Auto-Lock Interval',
            subtitle: 'Require PIN after being inactive',
            trailing: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: const [0, 30, 60, 180, 300, 900, 1800, 3600]
                        .contains(_autoLockSeconds)
                    ? _autoLockSeconds
                    : 1800,
                icon: Icon(Icons.arrow_drop_down, color: t.colorScheme.primary),
                dropdownColor: t.cardColor,
                style: TextStyle(
                  color: t.colorScheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                items: const [
                  DropdownMenuItem(value: 30, child: Text('30s')),
                  DropdownMenuItem(value: 60, child: Text('1m')),
                  DropdownMenuItem(value: 180, child: Text('3m')),
                  DropdownMenuItem(value: 300, child: Text('5m')),
                  DropdownMenuItem(value: 900, child: Text('15m')),
                  DropdownMenuItem(value: 1800, child: Text('30m')),
                  DropdownMenuItem(value: 3600, child: Text('1h')),
                  DropdownMenuItem(value: 0, child: Text('Never')),
                ],
                onChanged: (val) {
                  if (val != null) _saveAutoLock(val);
                },
              ),
            ),
            isDark: isDark,
          ),
          const SizedBox(height: 16),
          _buildSettingCard(
            context: context,
            icon: FontAwesomeIcons.fingerprint,
            title: 'Biometric Authentication',
            subtitle: 'Use fingerprint or FaceID to login',
            trailing: Switch(
              value: _biometricsEnabled,
              onChanged: _toggleBiometrics,
              activeThumbColor: t.colorScheme.primary,
            ),
            isDark: isDark,
          ),
        ],
      ),
    );
  }


  Widget _buildSettingCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
    required bool isDark,
  }) {
    final t = Theme.of(context);

    final card = Container(
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: t.colorScheme.primary, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: t.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );

    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: card,
      ),
    );
  }
}
