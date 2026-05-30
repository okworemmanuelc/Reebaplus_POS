import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';

/// CEO Settings > Security (§10.1). Auto-lock interval (synced, business-wide)
/// + biometric login (device-local).
class SecuritySettingsScreen extends ConsumerStatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  ConsumerState<SecuritySettingsScreen> createState() =>
      _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState
    extends ConsumerState<SecuritySettingsScreen> {
  /// Preset auto-lock intervals in seconds (§10.1: 1/3/5/10/15/30 min).
  static const _presets = [60, 180, 300, 600, 900, 1800];

  /// Default when unset (§10.1: 5 minutes). Matches AutoLockWrapper's fallback.
  static const _defaultSeconds = 300;

  int _autoLockSeconds = _defaultSeconds;
  bool _biometricsEnabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final intervalStr = await db.settingsDao.get('auto_lock_interval_seconds');
    final stored = int.tryParse(intervalStr ?? '');
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;
    setState(() {
      // Snap any legacy/non-preset value (or unset) to the default so the UI
      // and the chips stay consistent; a tap then persists a real preset.
      _autoLockSeconds =
          (stored != null && _presets.contains(stored)) ? stored : _defaultSeconds;
      _biometricsEnabled = prefs.getBool('biometrics_enabled') ?? false;
      _loading = false;
    });
  }

  Future<void> _saveAutoLock(int seconds) async {
    // ref.read (not hasPermission/watch) — callback, matches staff_detail_screen.
    if (!ref.read(currentUserPermissionsProvider).contains('settings.manage')) {
      AppNotification.showError(context, 'You don\'t have permission to do that.');
      return;
    }
    setState(() => _autoLockSeconds = seconds);
    final db = ref.read(databaseProvider);
    await db.settingsDao.set('auto_lock_interval_seconds', seconds.toString());
    await db.activityLogDao.log(
      action: 'settings.security.auto_lock',
      description: 'Set auto-lock to ${seconds ~/ 60} min',
      staffId: db.currentUserId,
    );
  }

  /// Biometric enablement is device-local: it persists to the same
  /// SharedPreferences key the login screen reads. No DB write, so no
  /// activity-log entry (it isn't a tenant data change).
  Future<void> _toggleBiometrics(bool enable) async {
    if (!enable) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('biometrics_enabled', false);
      if (mounted) setState(() => _biometricsEnabled = false);
      return;
    }

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
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('biometrics_enabled', true);
        if (mounted) setState(() => _biometricsEnabled = true);
      }
    } catch (_) {
      if (mounted) {
        AppNotification.showError(context, 'Failed to enable biometrics.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Screen-level gate (hard rule #6) + keeps the permission chain warm for
    // the save-site guard.
    final canManage = hasPermission(ref, 'settings.manage');
    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Security',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: !canManage
          ? const SettingsNoAccess()
          : _loading
          ? const SizedBox.shrink()
          : SettingsFadeIn(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  _autoLockCard(context),
                  const SizedBox(height: 16),
                  SettingsTile(
                    icon: Icons.fingerprint_rounded,
                    title: 'Biometric login',
                    subtitle: 'Use fingerprint or Face ID on this device',
                    trailing: Switch(
                      value: _biometricsEnabled,
                      onChanged: _toggleBiometrics,
                      activeThumbColor: t.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _autoLockCard(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.lock_clock_rounded,
                  color: t.colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Auto-lock',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: t.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Return to the sign-in picker after inactivity',
                      style: TextStyle(
                        fontSize: 13,
                        color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final seconds in _presets)
                ChoiceChip(
                  label: Text('${seconds ~/ 60} min'),
                  selected: _autoLockSeconds == seconds,
                  onSelected: (_) => _saveAutoLock(seconds),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
