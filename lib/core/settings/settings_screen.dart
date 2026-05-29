import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/activity_logs_access_screen.dart';
import 'package:reebaplus_pos/core/settings/business_info_screen.dart';
import 'package:reebaplus_pos/core/settings/security_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/settings/stores_settings_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/coming_soon_screen.dart';

/// CEO Settings menu (§10.1). Each row opens its own sub-page. Reached from the
/// drawer, which already hides this for non-CEO roles; the guard below is
/// defense-in-depth (hard rule #6).
///
/// Roles & Permissions (§10.2) is deferred — it routes to a Coming Soon
/// placeholder for now.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);

    final canManage = hasPermission(ref, 'settings.manage');

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'CEO Settings',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: !canManage
          ? const SettingsNoAccess()
          : SettingsFadeIn(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  SettingsTile(
                    icon: Icons.business_rounded,
                    title: 'Business Info',
                    subtitle: 'Name, type, and currency',
                    trailing: _chevron(context),
                    onTap: () => _open(context, const BusinessInfoScreen()),
                  ),
                  const SizedBox(height: 16),
                  SettingsTile(
                    icon: Icons.store_rounded,
                    title: 'Stores',
                    subtitle: 'Your store locations',
                    trailing: _chevron(context),
                    onTap: () => _open(context, const StoresSettingsScreen()),
                  ),
                  const SizedBox(height: 16),
                  SettingsTile(
                    icon: Icons.lock_rounded,
                    title: 'Security',
                    subtitle: 'Auto-lock and biometric login',
                    trailing: _chevron(context),
                    onTap: () => _open(context, const SecuritySettingsScreen()),
                  ),
                  const SizedBox(height: 16),
                  SettingsTile(
                    icon: Icons.admin_panel_settings_rounded,
                    title: 'Roles & Permissions',
                    subtitle: 'What each role can do',
                    trailing: _chevron(context),
                    onTap: () => _open(
                      context,
                      const ComingSoonScreen(
                        title: 'Roles & Permissions',
                        message:
                            'Fine-grained role controls are coming in a future update.',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SettingsTile(
                    icon: Icons.fact_check_rounded,
                    title: 'Activity Logs access',
                    subtitle: 'Which roles can view activity logs',
                    trailing: _chevron(context),
                    onTap: () =>
                        _open(context, const ActivityLogsAccessScreen()),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _chevron(BuildContext context) => Icon(
        Icons.chevron_right,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
      );

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }
}
