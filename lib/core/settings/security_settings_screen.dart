import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_page_parts.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

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
      // 0 is an explicit "off" value (auto-lock disabled). Snap any other
      // legacy/non-preset value (or unset) to the default so the UI and the
      // chips stay consistent; a tap then persists a real preset.
      _autoLockSeconds = (stored != null && (stored == 0 || _presets.contains(stored)))
          ? stored
          : _defaultSeconds;
      _biometricsEnabled = prefs.getBool('biometrics_enabled') ?? false;
      _loading = false;
    });
  }

  Future<void> _saveAutoLock(int seconds) async {
    // Fire-time re-check (allowsNow, not allows) — callback, not a build.
    if (!Gates.manageSettings.allowsNow(ref)) {
      showGateDenied(context, Gates.manageSettings);
      return;
    }
    setState(() => _autoLockSeconds = seconds);
    final db = ref.read(databaseProvider);
    final off = seconds == 0;
    try {
      await db.settingsDao.set(
        'auto_lock_interval_seconds',
        seconds.toString(),
      );
      await db.activityLogDao.log(
        action: 'settings.security.auto_lock',
        description:
            off ? 'Turned auto-lock off' : 'Set auto-lock to ${seconds ~/ 60} min',
        staffId: db.currentUserId,
      );
      if (mounted) {
        AppNotification.showSuccess(
          context,
          off ? 'Auto-lock turned off.' : 'Auto-lock updated.',
        );
      }
    } catch (_) {
      if (mounted) {
        AppNotification.showError(context, 'Couldn\'t update auto-lock.');
      }
    }
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
    final canManage = Gates.manageSettings.allows(ref);
    return SettingsPageScaffold(
      icon: AppIcons.lock,
      title: 'Security',
      body: !canManage
          ? const SettingsNoAccess()
          : _loading
          ? const SizedBox.shrink()
          : SettingsFadeIn(
              child: SettingsPageList(
                listKey: const Key('security-list'),
                children: [
                  _autoLockCard(context),
                  SizedBox(height: context.getRSize(12)),
                  SettingsCard(
                    child: SettingsControlRow(
                      icon: AppIcons.biometrics,
                      tone: IconTileTone.info,
                      title: 'Biometric login',
                      subtitle: 'Use fingerprint or Face ID on this device',
                      trailing: Switch(
                        value: _biometricsEnabled,
                        onChanged: _toggleBiometrics,
                        activeThumbColor: t.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _autoLockCard(BuildContext context) {
    final t = Theme.of(context);
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsControlRow(
            icon: AppIcons.lockClock,
            tone: IconTileTone.danger,
            title: 'Auto-lock',
            subtitle: _autoLockSeconds == 0
                ? 'Off — tap a timer to turn it on'
                : 'Return to the sign-in picker after inactivity',
          ),
          SizedBox(height: context.getRSize(16)),
          Wrap(
            spacing: context.getRSize(8),
            runSpacing: context.getRSize(8),
            children: [
              for (final seconds in _presets)
                () {
                  final selected = _autoLockSeconds == seconds;
                  return ChoiceChip(
                    label: Text('${seconds ~/ 60} min'),
                    selected: selected,
                    // Explicit colors so the unselected label stays legible in
                    // both light and dark themes (the chip theme's light label
                    // tint washed out on the light surface).
                    backgroundColor: t.colorScheme.surface,
                    selectedColor: t.colorScheme.primary,
                    checkmarkColor: t.colorScheme.onPrimary,
                    side: BorderSide(color: t.dividerColor),
                    labelStyle: context
                        .semiBoldStyle(13)
                        .copyWith(
                          color: selected
                              ? t.colorScheme.onPrimary
                              : t.colorScheme.onSurface,
                        ),
                    // Re-tapping the active chip turns auto-lock off (saves 0).
                    onSelected: (_) => _saveAutoLock(selected ? 0 : seconds),
                  );
                }(),
            ],
          ),
        ],
      ),
    );
  }
}
