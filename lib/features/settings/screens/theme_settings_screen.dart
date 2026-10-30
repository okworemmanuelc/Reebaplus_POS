import 'package:flutter/material.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_page_parts.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Per-device display settings — light / dark / system. Pushed from the drawer
/// ("Display"). The business *accent colour* is NOT here: it's CEO-controlled
/// and synced, under CEO Settings → Appearance (§10.1).
///
/// Restyled in #442 (PRD #346 Wave 2 C): solid top bar, 720 cap, one card per
/// mode with the active one outlined in the primary colour.
class ThemeSettingsScreen extends StatelessWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return SettingsPageScaffold(
      icon: AppIcons.themeMode,
      title: 'Display',
      body: ListenableBuilder(
        listenable: themeController,
        builder: (_, _) {
          return SettingsPageList(
            listKey: const Key('display-list'),
            children: [
              const SectionHeader(title: 'Appearance Mode'),
              SizedBox(height: context.getRSize(4)),
              Text(
                'Applies to this device only.',
                style: context.regularStyle(13).copyWith(color: muted),
              ),
              SizedBox(height: context.getRSize(12)),
              _ModeTile(
                icon: AppIcons.lightMode,
                label: 'Light',
                isActive: themeController.themeMode == ThemeMode.light,
                onTap: () => themeController.setTheme(ThemeMode.light),
              ),
              SizedBox(height: context.getRSize(8)),
              _ModeTile(
                icon: AppIcons.darkMode,
                label: 'Dark',
                isActive: themeController.themeMode == ThemeMode.dark,
                onTap: () => themeController.setTheme(ThemeMode.dark),
              ),
              SizedBox(height: context.getRSize(8)),
              _ModeTile(
                icon: AppIcons.terminal,
                label: 'System',
                isActive: themeController.themeMode == ThemeMode.system,
                onTap: () => themeController.setTheme(ThemeMode.system),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Appearance Mode Tile
// ─────────────────────────────────────────────────────────────────────────────

class _ModeTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _ModeTile({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: AppDecorations.card(context).copyWith(
        border: Border.all(
          color: isActive ? primary : t.dividerColor,
          width: isActive ? 2 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(14)),
              child: Row(
                children: [
                  IconTile(
                    icon: icon,
                    size: 40,
                    tone: isActive ? IconTileTone.info : IconTileTone.neutral,
                  ),
                  SizedBox(width: context.getRSize(14)),
                  Expanded(
                    child: Text(
                      label,
                      style:
                          (isActive
                                  ? context.boldStyle(16)
                                  : context.mediumStyle(16))
                              .copyWith(
                                color: isActive
                                    ? primary
                                    : t.colorScheme.onSurface,
                              ),
                    ),
                  ),
                  if (isActive)
                    AppIcon(
                      AppIcons.checkCircle,
                      filled: true,
                      size: context.getRSize(22),
                      color: primary,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
