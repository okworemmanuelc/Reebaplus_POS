import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/activity_logs_access_screen.dart';
import 'package:reebaplus_pos/core/settings/appearance_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/business_info_screen.dart';
import 'package:reebaplus_pos/core/settings/roles_permissions_screen.dart';
import 'package:reebaplus_pos/core/settings/security_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/settings/stores_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/subscription_screen.dart';
import 'package:reebaplus_pos/core/settings/sync_issues_access_screen.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// One row in the CEO Settings menu.
typedef _SettingEntry = ({
  IconData icon,
  String title,
  String subtitle,
  Widget screen,
});

/// CEO Settings menu (§10.1). Each row opens its own sub-page. Reached from the
/// drawer, which already hides this for non-CEO roles; the guard below is
/// defense-in-depth (hard rule #6). A search box filters the rows by title /
/// subtitle so a specific setting is quick to find.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  // Const instances are canonicalised (no per-build construction cost).
  static const List<_SettingEntry> _entries = [
    (
      icon: Icons.business_rounded,
      title: 'Business Info',
      subtitle: 'Name, type, and currency',
      screen: BusinessInfoScreen(),
    ),
    (
      icon: Icons.workspace_premium_rounded,
      title: 'Subscription',
      subtitle: 'Plan, status, and renewal',
      screen: SubscriptionScreen(),
    ),
    (
      icon: Icons.store_rounded,
      title: 'Stores',
      subtitle: 'Your store locations',
      screen: StoresSettingsScreen(),
    ),
    (
      icon: Icons.lock_rounded,
      title: 'Security',
      subtitle: 'Auto-lock and biometric login',
      screen: SecuritySettingsScreen(),
    ),
    (
      icon: Icons.admin_panel_settings_rounded,
      title: 'Roles & Permissions',
      subtitle: 'What each role can do',
      screen: RolesPermissionsScreen(),
    ),
    (
      icon: Icons.fact_check_rounded,
      title: 'Activity Logs access',
      subtitle: 'Which roles can view activity logs',
      screen: ActivityLogsAccessScreen(),
    ),
    (
      icon: Icons.cloud_sync_rounded,
      title: 'Sync Issues access',
      subtitle: 'Which roles can open Sync Issues',
      screen: SyncIssuesAccessScreen(),
    ),
    (
      icon: Icons.palette_rounded,
      title: 'Appearance',
      subtitle: 'Business colour (applies to all devices)',
      screen: AppearanceSettingsScreen(),
    ),
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final canManage = hasPermission(ref, 'settings.manage');

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _entries
        : _entries
            .where((e) =>
                e.title.toLowerCase().contains(q) ||
                e.subtitle.toLowerCase().contains(q))
            .toList();

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
                padding: EdgeInsets.fromLTRB(
                    24, 24, 24, 24 + context.deviceBottomInset),
                children: [
                  TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search settings',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: q.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded),
                              tooltip: 'Clear',
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                            ),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Center(
                        child: Text(
                          'No settings match "${_query.trim()}".',
                          style: TextStyle(
                            color:
                                t.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ),
                  for (final e in filtered) ...[
                    SettingsTile(
                      icon: e.icon,
                      title: e.title,
                      subtitle: e.subtitle,
                      trailing: _chevron(context),
                      onTap: () => _open(context, e.screen),
                    ),
                    const SizedBox(height: 16),
                  ],
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
