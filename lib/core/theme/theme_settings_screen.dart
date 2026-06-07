import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';

/// Per-device display settings — light / dark / system. Pushed from the drawer
/// ("Display"). The business *accent colour* is NOT here: it's CEO-controlled
/// and synced, under CEO Settings → Appearance (§10.1).
class ThemeSettingsScreen extends StatelessWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Display'),
        centerTitle: false,
      ),
      body: ListenableBuilder(
        listenable: themeController,
        builder: (_, __) {
          return ListView(
            padding: EdgeInsets.fromLTRB(
              context.getRSize(20),
              context.getRSize(24),
              context.getRSize(20),
              context.getRSize(24) + context.deviceBottomPadding,
            ),
            children: [
              Text(
                'Appearance Mode',
                style: t.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: context.getRSize(4)),
              Text(
                'Applies to this device only.',
                style: t.textTheme.bodySmall?.copyWith(
                  color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              SizedBox(height: context.getRSize(12)),
              _ModeTile(
                icon: FontAwesomeIcons.sun,
                label: 'Light',
                isActive: themeController.themeMode == ThemeMode.light,
                onTap: () => themeController.setTheme(ThemeMode.light),
              ),
              SizedBox(height: context.getRSize(8)),
              _ModeTile(
                icon: FontAwesomeIcons.moon,
                label: 'Dark',
                isActive: themeController.themeMode == ThemeMode.dark,
                onTap: () => themeController.setTheme(ThemeMode.dark),
              ),
              SizedBox(height: context.getRSize(8)),
              _ModeTile(
                icon: FontAwesomeIcons.desktop,
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
    return Material(
      color: isActive ? primary.withValues(alpha: 0.1) : t.colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(16),
            vertical: context.getRSize(14),
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? primary : t.dividerColor,
              width: isActive ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: context.getRSize(18),
                color: isActive ? primary : t.iconTheme.color,
              ),
              SizedBox(width: context.getRSize(14)),
              Expanded(
                child: Text(
                  label,
                  style: t.textTheme.bodyLarge?.copyWith(
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                    color: isActive ? primary : t.colorScheme.onSurface,
                  ),
                ),
              ),
              if (isActive)
                Icon(
                  Icons.check_circle,
                  size: context.getRSize(20),
                  color: primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
