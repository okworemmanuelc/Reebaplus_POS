import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/staff/widgets/staff_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Keys for the permission screens (#440 part 2).
abstract final class PermissionKeys {
  static const Key list = ValueKey<String>('permissions-list');
  static const Key scopeBusiness = ValueKey<String>('permissions-scope-business');
  static const Key scopeStore = ValueKey<String>('permissions-scope-store');
  static const Key discountCard = ValueKey<String>('permissions-discount-card');
  static const Key expenseCard = ValueKey<String>('permissions-expense-card');
  static const Key expenseField = ValueKey<String>('permissions-expense-field');
  static const Key rolesList = ValueKey<String>('roles-list');

  static Key roleRow(String slug) => ValueKey<String>('roles-row-$slug');
}

/// Top bar of a pushed permissions screen: 48dp back, tile, [title].
class PermissionTopBar extends StatelessWidget implements PreferredSizeWidget {
  const PermissionTopBar({
    super.key,
    required this.height,
    required this.title,
    this.subtitle,
    this.icon = AppIcons.userPermissions,
  });

  final double height;
  final String title;
  final String? subtitle;
  final IconData icon;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    return StaffTopBar(
      height: height,
      header: ScreenHeader(
        icon: icon,
        title: title,
        subtitle: subtitle,
        leading: const StaffBackButton(),
      ),
    );
  }
}

/// The page shell: soft fade, solid top bar, side-inset safe body.
class PermissionPage extends StatelessWidget {
  const PermissionPage({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = AppIcons.userPermissions,
    required this.body,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: PermissionTopBar(
          key: StaffKeys.topBar,
          height: staffTopBarHeight(context),
          title: title,
          subtitle: subtitle,
          icon: icon,
        ),
        body: SafeArea(top: false, bottom: false, child: body),
      ),
    );
  }
}

/// Centred muted message (no access, load error), same words as before.
class PermissionMessage extends StatelessWidget {
  const PermissionMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: context.regularStyle(14).copyWith(color: muted),
        ),
      ),
    );
  }
}

/// A muted explanatory paragraph.
class PermissionIntro extends StatelessWidget {
  const PermissionIntro(this.text, {super.key, this.size = 13});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Text(
      text,
      style: context.regularStyle(size).copyWith(color: muted, height: 1.4),
    );
  }
}

/// One toggle: title, optional subtitle (emphasised when overridden).
class PermissionToggle {
  const PermissionToggle({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.emphasis = false,
    this.dimSubtitle = false,
  });

  final String title;
  final bool value;

  /// Null = locked (CEO, or a child whose parent is off).
  final ValueChanged<bool>? onChanged;
  final String? subtitle;
  final bool emphasis;
  final bool dimSubtitle;
}

/// A flat card of [SwitchListTile]s (48dp+ each).
class PermissionToggleCard extends StatelessWidget {
  const PermissionToggleCard({super.key, required this.toggles});

  final List<PermissionToggle> toggles;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (var i = 0; i < toggles.length; i++) ...[
              SwitchListTile(
                title: Text(
                  toggles[i].title,
                  style: context
                      .semiBoldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                subtitle: toggles[i].subtitle == null
                    ? null
                    : Text(
                        toggles[i].subtitle!,
                        style:
                            (toggles[i].emphasis
                                    ? context.boldStyle(12)
                                    : context.regularStyle(12))
                                .copyWith(
                                  color: toggles[i].dimSubtitle
                                      ? muted.withValues(alpha: 0.8)
                                      : (toggles[i].emphasis
                                            ? t.colorScheme.primary
                                            : muted),
                                ),
                      ),
                value: toggles[i].value,
                onChanged: toggles[i].onChanged,
                activeThumbColor: t.colorScheme.onPrimary,
                activeTrackColor: t.colorScheme.primary,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(16),
                  vertical: context.getRSize(2),
                ),
              ),
              if (i < toggles.length - 1)
                Divider(height: 1, color: t.dividerColor),
            ],
          ],
        ),
      ),
    );
  }
}

/// A flat card with padding for a limit control (discount, expense).
class PermissionLimitCard extends StatelessWidget {
  const PermissionLimitCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: child,
      ),
    );
  }
}

/// Business / Store pill toggle (>= 48dp segments).
class PermissionScopeToggle extends StatelessWidget {
  const PermissionScopeToggle({
    super.key,
    required this.storeScope,
    required this.onChanged,
  });

  final bool storeScope;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(4)),
        child: Row(
          children: [
            _segment(
              context,
              PermissionKeys.scopeBusiness,
              'Business',
              !storeScope,
              () => onChanged(false),
            ),
            _segment(
              context,
              PermissionKeys.scopeStore,
              'Store',
              storeScope,
              () => onChanged(true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    Key key,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Expanded(
      child: GestureDetector(
        key: key,
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          alignment: Alignment.center,
          decoration: selected
              ? AppDecorations.primaryButtonGradient(
                  context,
                  radius: AppSpacing.borderRadiusL,
                )
              : null,
          child: Text(
            label,
            style: context
                .boldStyle(14)
                .copyWith(
                  color: selected ? t.colorScheme.onPrimary : muted,
                ),
          ),
        ),
      ),
    );
  }
}

/// Store-scope note card (CEO role, or no stores yet).
class PermissionNoteCard extends StatelessWidget {
  const PermissionNoteCard({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(24)),
        child: Column(
          children: [
            const IconTile(icon: AppIcons.storefront, tone: IconTileTone.neutral),
            SizedBox(height: context.getRSize(12)),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.regularStyle(13).copyWith(color: muted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
