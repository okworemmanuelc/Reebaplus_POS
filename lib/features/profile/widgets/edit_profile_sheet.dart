import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/avatar_helpers.dart';

/// Bottom-sheet for editing the current user's own name + avatar colour
/// (self-service, §27.1). Opened from the Profile screen and from the Staff
/// Settings page (§10.5). Local state (name field + swatch selection) lives
/// here so taps update live without rebuilding the parent screen.
///
/// Open it with:
///   showModalBottomSheet(
///     context: context, isScrollControlled: true,
///     backgroundColor: Colors.transparent,
///     builder: (_) => EditProfileSheet(user: user, parentRef: ref));
class EditProfileSheet extends StatefulWidget {
  final UserData user;
  final WidgetRef parentRef;
  const EditProfileSheet({
    super.key,
    required this.user,
    required this.parentRef,
  });

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
        name != widget.user.name.trim() || _selectedHex != widget.user.avatarColor;

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
      final editorSlug =
          widget.parentRef.read(currentUserRoleProvider)?.slug;
      if (changed && editorSlug != null && editorSlug != 'ceo') {
        final recipients =
            await db.userBusinessesDao.getUserIdsForRoleSlugs(['ceo', 'manager']);
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
    return Container(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        24 + context.deviceBottomPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: t.colorScheme.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Edit Profile',
            style: TextStyle(
              fontSize: context.getRFontSize(18),
              fontWeight: FontWeight.bold,
              color: t.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: AppDecorations.authInputDecoration(
              context,
              label: 'Name',
              prefixIcon: Icons.person_rounded,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Avatar colour',
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w600,
              color: t.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final hex in _swatches)
                GestureDetector(
                  onTap: () => setState(() => _selectedHex = hex),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: parseHexColor(hex),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _selectedHex == hex
                            ? t.colorScheme.onSurface
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: _selectedHex == hex
                        ? const Icon(Icons.check_rounded,
                            color: Colors.white, size: 20)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _saving ? null : _save,
            child: Opacity(
              opacity: _saving ? 0.6 : 1,
              child: Container(
                height: 54,
                alignment: Alignment.center,
                decoration: AppDecorations.primaryGradient(context, radius: 14),
                child: const Text(
                  'Save changes',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
