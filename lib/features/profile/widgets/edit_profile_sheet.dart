import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/settings/settings_page_parts.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/avatar_helpers.dart';

/// Bottom-sheet for editing the current user's own name + avatar colour
/// (self-service, §27.1). Opened from the Profile screen and from the Staff
/// Settings page (§10.5). Local state (name field + swatch selection) lives
/// here so taps update live without rebuilding the parent screen.
///
/// Open it with [EditProfileSheet.show] (the theme draws the surface; capped
/// at Material 3's 640 on wide screens).
class EditProfileSheet extends StatefulWidget {
  final UserData user;
  final WidgetRef parentRef;
  const EditProfileSheet({
    super.key,
    required this.user,
    required this.parentRef,
  });

  /// Opens the sheet: scroll-controlled, capped at 640dp.
  static Future<void> show(
    BuildContext context, {
    required UserData user,
    required WidgetRef parentRef,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: kSettingsSheetMaxWidth),
    builder: (_) => EditProfileSheet(user: user, parentRef: parentRef),
  );

  @override
  State<EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<EditProfileSheet> {
  static const _swatches = [
    '#3B82F6',
    '#22C55E',
    '#F59E0B',
    '#EF4444',
    '#A855F7',
    '#EC4899',
    '#14B8A6',
    '#6B7280',
  ];

  late final TextEditingController _nameController;
  late String _selectedHex;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.user.name);
    _selectedHex = _swatches.contains(widget.user.avatarColor)
        ? widget.user.avatarColor
        : _swatches.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.length < 2) {
      AppNotification.showError(context, 'Enter at least 2 characters.');
      return;
    }

    final changed =
        name != widget.user.name.trim() ||
        _selectedHex != widget.user.avatarColor;

    setState(() => _saving = true);
    final db = widget.parentRef.read(databaseProvider);
    try {
      await db.storesDao.updateUserProfile(
        id: widget.user.id,
        name: name,
        avatarColor: _selectedHex,
      );
      await widget.parentRef.read(authProvider).refreshCurrentUser();
      await db.activityLogDao.log(
        action: 'settings.profile.update',
        description: 'Updated profile (name, avatar)',
        staffId: db.currentUserId,
      );
      // §26.4 — "Staff updated their profile (fires to CEO + Manager)". Only
      // when the editor is below CEO and something actually changed; a CEO
      // editing their own profile does not notify. The actor is never
      // self-notified. fireNotification routes through enqueueUpsert (synced),
      // so it reaches each recipient's device live.
      final editorSlug = widget.parentRef.read(currentUserRoleProvider)?.slug;
      if (changed && editorSlug != null && editorSlug != 'ceo') {
        final recipients = await db.userBusinessesDao.getUserIdsForRoleSlugs([
          'ceo',
          'manager',
        ]);
        for (final recipientId in recipients) {
          if (recipientId == widget.user.id) continue;
          await db.notificationsDao.fireNotification(
            type: 'staff.profile_updated',
            message: '$name updated their profile information',
            linkedRecordId: widget.user.id,
            recipientUserId: recipientId,
          );
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      AppNotification.showSuccess(context, 'Profile updated.');
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(context, 'Couldn\'t update profile.');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fixed = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final gutter = context.getRSize(20);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    // One shrink-wrapped scroll view capped at 90% of the screen height (the
    // customer sheets' frame): the name box and Save stay reachable at 360dp
    // @1.15 and at 844x390 with the keyboard up. The theme draws the Surface
    // and shape.
    return ConstrainedBox(
      key: const Key('edit-profile-sheet'),
      constraints: BoxConstraints(maxHeight: context.screenHeight * 0.9),
      child: CustomScrollView(
        shrinkWrap: true,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              context.getRSize(12),
              gutter,
              // A modal sheet sits on the root navigator, above MainLayout's
              // Scaffold, so nothing resizes it for the keyboard: lift by the
              // keyboard here. deviceBottomPadding collapses to 0 while the
              // keyboard is up, so the two never double-count.
              context.getRSize(16) +
                  context.deviceBottomPadding +
                  MediaQuery.viewInsetsOf(context).bottom,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: context.getRSize(40),
                      height: context.getRSize(4),
                      decoration: BoxDecoration(
                        color: t.dividerColor,
                        borderRadius: BorderRadius.circular(
                          AppSpacing.borderRadiusS,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: context.getRSize(16)),
                  const ScreenHeader(
                    icon: AppIcons.user,
                    title: 'Edit Profile',
                  ),
                  SizedBox(height: context.getRSize(20)),
                  AppInput(
                    controller: _nameController,
                    labelText: 'Name',
                    textCapitalization: TextCapitalization.words,
                    prefixIcon: Icon(AppIcons.user, color: muted),
                  ),
                  SizedBox(height: context.getRSize(20)),
                  Text(
                    'Avatar colour',
                    style: context.semiBoldStyle(13).copyWith(color: muted),
                  ),
                  SizedBox(height: context.getRSize(8)),
                  Wrap(
                    spacing: context.getRSize(8),
                    runSpacing: context.getRSize(8),
                    children: [
                      for (final hex in _swatches)
                        _Swatch(
                          hex: hex,
                          selected: _selectedHex == hex,
                          checkColor: fixed.onSolid,
                          onTap: () => setState(() => _selectedHex = hex),
                        ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(24)),
                  AppButton(
                    text: 'Save changes',
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One avatar-colour choice: a 48dp tap target around a 44dp circle.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.hex,
    required this.selected,
    required this.checkColor,
    required this.onTap,
  });

  final String hex;
  final bool selected;
  final Color checkColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkResponse(
      onTap: onTap,
      radius: kMinInteractiveDimension / 2,
      child: SizedBox(
        width: kMinInteractiveDimension,
        height: kMinInteractiveDimension,
        child: Center(
          child: Container(
            width: context.getRSize(44),
            height: context.getRSize(44),
            decoration: BoxDecoration(
              color: parseHexColor(hex),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? t.colorScheme.onSurface : Colors.transparent,
                width: 3,
              ),
            ),
            child: selected
                ? AppIcon(
                    AppIcons.check,
                    color: checkColor,
                    size: context.getRSize(20),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
