import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// CEO Settings > Appearance (§10.1). The CEO picks the **business** accent
/// colour — synced via the `business_design_system` setting and applied to
/// every device (see the bridge in main.dart). Light/dark/system mode is NOT
/// here — that's a per-device choice under "Display" in the drawer.

const kAppearanceCardKeyPrefix = 'appearance-card-';
const kAppearanceCheckBadgeKeyPrefix = 'appearance-check-badge-';
const kAppearanceSwatchKeyPrefix = 'appearance-swatch-';

Key appearanceCardKey(DesignSystem ds) => Key('$kAppearanceCardKeyPrefix${ds.name}');
Key appearanceCheckBadgeKey(DesignSystem ds) => Key('$kAppearanceCheckBadgeKeyPrefix${ds.name}');
Key appearanceSwatchKey(DesignSystem ds, int index) => Key('$kAppearanceSwatchKeyPrefix${ds.name}-$index');

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
      swatch: [greenContrast, greenDark, Color(0xFF4ADE80)],
    ),
    (
      label: 'Black & White',
      ds: DesignSystem.bw,
      swatch: [Color(0xFF111111), Color(0xFF757575), Color(0xFFE0E0E0)],
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canManage = Gates.manageSettings.allows(ref);
    // Synced value when set; otherwise reflect what this device is showing.
    final current =
        ref.watch(businessDesignSystemProvider).valueOrNull ??
        themeController.designSystem;

    return GlassyScaffold(
      title: 'Appearance',
      body: !canManage
          ? const SettingsNoAccess()
          : SettingsFadeIn(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(20),
                  context.getRSize(24),
                  context.getRSize(20),
                  context.getRSize(24) + context.deviceBottomPadding,
                ),
                children: [
                  Text(
                    'Pick the colour for the whole business. It applies to every '
                    'device. Light and dark mode stays a personal choice under '
                    'Display.',
                    style: t.textTheme.bodyMedium?.copyWith(
                      color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  SizedBox(height: context.getRSize(20)),
                  for (var i = 0; i < _options.length; i += 2) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _AccentCard(
                            option: _options[i],
                            isActive: _options[i].ds == current,
                            onTap: () => _select(context, ref, _options[i].ds),
                          ),
                        ),
                        SizedBox(width: context.getRSize(12)),
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
                    SizedBox(height: context.getRSize(12)),
                  ],
                ],
              ),
            ),
    );
  }

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    DesignSystem ds,
  ) async {
    // Fire-time re-check (allowsNow), matching the other settings sub-pages.
    if (!Gates.manageSettings.allowsNow(ref)) {
      showGateDenied(context, Gates.manageSettings);
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
    final checkIconColor =
        ThemeData.estimateBrightnessForColor(activeColor) == Brightness.light
            ? Colors.black
            : Colors.white;

    return GestureDetector(
      key: appearanceCardKey(option.ds),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: BoxDecoration(
          color: t.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? activeColor : t.dividerColor,
            width: isActive ? 2 : 1,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double swatchSize;
            final double swatchGap;
            final double badgeSize;
            final double iconSize;

            if (constraints.maxWidth < 100) {
              swatchSize = 18.0;
              swatchGap = 3.0;
              badgeSize = 18.0;
              iconSize = 11.0;
            } else if (constraints.maxWidth < 120) {
              swatchSize = 20.0;
              swatchGap = 4.0;
              badgeSize = 20.0;
              iconSize = 12.0;
            } else {
              swatchSize = 24.0;
              swatchGap = 6.0;
              badgeSize = 24.0;
              iconSize = 14.0;
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < option.swatch.length; i++) ...[
                      Container(
                        key: appearanceSwatchKey(option.ds, i),
                        width: swatchSize,
                        height: swatchSize,
                        decoration: BoxDecoration(
                          color: option.swatch[i],
                          shape: BoxShape.circle,
                          border: Border.all(color: t.dividerColor),
                        ),
                      ),
                      if (i < option.swatch.length - 1)
                        SizedBox(width: swatchGap),
                    ],
                    const Spacer(),
                    if (isActive)
                      Container(
                        key: appearanceCheckBadgeKey(option.ds),
                        width: badgeSize,
                        height: badgeSize,
                        decoration: BoxDecoration(
                          color: activeColor,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check,
                          size: iconSize,
                          color: checkIconColor,
                        ),
                      ),
                  ],
                ),
                SizedBox(height: context.getRSize(12)),
                Text(
                  option.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.getRFontSize(14),
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                    color: isActive ? activeColor : t.colorScheme.onSurface,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
