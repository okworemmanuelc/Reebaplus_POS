import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// CEO Settings > Appearance (§10.1). The CEO picks the **business** accent
/// colour — synced via the `business_design_system` setting and applied to
/// every device (see the bridge in main.dart). Light/dark/system mode is NOT
/// here — that's a per-device choice under "Display" in the drawer.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  static const List<({String label, DesignSystem ds, List<Color> swatch})>
      _options = [
    (
      label: 'Amber',
      ds: DesignSystem.amber,
      swatch: [amberPrimary, amberDark, Color(0xFFFFBF4A)],
    ),
    (
      label: 'Blue',
      ds: DesignSystem.blue,
      swatch: [blueMain, blueDark, blueLight],
    ),
    (
      label: 'Purple',
      ds: DesignSystem.purple,
      swatch: [purplePrimary, purpleDark, Color(0xFFA78BFA)],
    ),
    (
      label: 'Green',
      ds: DesignSystem.green,
      swatch: [greenPrimary, greenDark, Color(0xFF6EE7B7)],
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canManage = hasPermission(ref, 'settings.manage');
    // Synced value when set; otherwise reflect what this device is showing.
    final current = ref.watch(businessDesignSystemProvider).valueOrNull ??
        themeController.designSystem;

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Appearance',
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
                  Text(
                    'Pick the colour for the whole business. It applies to every '
                    'device. Light and dark mode stays a personal choice under '
                    'Display.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (var i = 0; i < _options.length; i += 2) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _AccentCard(
                            option: _options[i],
                            isActive: _options[i].ds == current,
                            onTap: () => _select(context, ref, _options[i].ds),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (i + 1 < _options.length)
                          Expanded(
                            child: _AccentCard(
                              option: _options[i + 1],
                              isActive: _options[i + 1].ds == current,
                              onTap: () =>
                                  _select(context, ref, _options[i + 1].ds),
                            ),
                          )
                        else
                          const Expanded(child: SizedBox()),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
    );
  }

  Future<void> _select(
      BuildContext context, WidgetRef ref, DesignSystem ds) async {
    // Callback re-check (ref.read), matching the other settings sub-pages.
    if (!ref.read(currentUserPermissionsProvider).contains('settings.manage')) {
      AppNotification.showError(
          context, 'You don\'t have permission to do that.');
      return;
    }
    themeController.setDesignSystem(ds); // immediate, this device
    final db = ref.read(databaseProvider);
    try {
      await db.settingsDao.set(kBusinessDesignSystemKey, ds.name); // synced
      await db.activityLogDao.log(
        action: 'settings.appearance.accent',
        description: 'Set business colour to ${ds.name}',
        staffId: db.currentUserId,
      );
      if (context.mounted) {
        AppNotification.showSuccess(context, 'Appearance updated.');
      }
    } catch (_) {
      if (context.mounted) {
        AppNotification.showError(context, 'Couldn\'t update appearance.');
      }
    }
  }
}

class _AccentCard extends StatelessWidget {
  final ({String label, DesignSystem ds, List<Color> swatch}) option;
  final bool isActive;
  final VoidCallback onTap;

  const _AccentCard({
    required this.option,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final activeColor = option.swatch.first;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? activeColor : t.dividerColor,
            width: isActive ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var i = 0; i < option.swatch.length; i++) ...[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: option.swatch[i],
                      shape: BoxShape.circle,
                      border: Border.all(color: t.dividerColor),
                    ),
                  ),
                  if (i < option.swatch.length - 1) const SizedBox(width: 6),
                ],
                const Spacer(),
                if (isActive)
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: activeColor,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check, size: 14, color: Colors.black),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              option.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isActive ? activeColor : t.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
