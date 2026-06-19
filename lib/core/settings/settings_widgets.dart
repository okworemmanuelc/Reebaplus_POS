import 'package:flutter/material.dart';

import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';

/// Shared building blocks for the CEO Settings menu (§10.1) and its sub-pages.
/// Kept tiny and local to the settings feature — no speculative design-system.

/// Uppercase-ish section label above a group of cards. Matches the header
/// style the flat Settings screen used before the §10.1 menu rebuild.
class SettingsSectionTitle extends StatelessWidget {
  final String text;
  const SettingsSectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: t.colorScheme.primary,
        letterSpacing: 1.2,
      ),
    );
  }
}

/// Glass card row: leading icon tile + title + subtitle + optional trailing.
/// Tappable when [onTap] is provided (menu rows); otherwise a static info row
/// (e.g. the read-only Stores list). Generalised from the old
/// `_buildSettingCard` helper.
class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    final card = GlassyCard(
      padding: const EdgeInsets.all(16),
      radius: 16,
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
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 13,
                      color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
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

/// Shown as a settings page body when the viewer lacks `settings.manage`
/// (hard rule #6 — every screen re-checks). Reached only via the gated menu,
/// so this is defense-in-depth.
class SettingsNoAccess extends StatelessWidget {
  const SettingsNoAccess({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Text(
        'You don\'t have access to settings.',
        style: TextStyle(color: t.colorScheme.onSurface.withValues(alpha: 0.6)),
      ),
    );
  }
}

/// Subtle fade-in wrapper for loaded content (§30.7 — no spinners). Mirrors the
/// `_BrandedFade` pattern from who_is_working_screen.dart.
class SettingsFadeIn extends StatelessWidget {
  final Widget child;
  const SettingsFadeIn({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeIn,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: child,
    );
  }
}
