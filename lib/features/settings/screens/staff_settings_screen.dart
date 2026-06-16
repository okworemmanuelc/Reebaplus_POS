import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/theme_settings_screen.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/profile/widgets/edit_profile_sheet.dart';

/// Staff Settings (§10.5) — the self-service settings home for roles **below
/// CEO** (Manager, Cashier, Stock keeper). Personal, not business-wide: edit
/// own name/avatar, change the unlock PIN, and pick the per-device Display mode
/// (moved here from the side menu for these roles). The CEO never sees this —
/// they use CEO Settings. Role-gated here as defense-in-depth (hard rule #6);
/// the drawer already hides it for the CEO.
class StaffSettingsScreen extends ConsumerWidget {
  const StaffSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final user = ref.watch(authProvider).currentUser;
    final slug = ref.watch(currentUserRoleProvider)?.slug;

    final body = _buildBody(context, ref, user, slug);

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: body,
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    UserData? user,
    String? slug,
  ) {
    final t = Theme.of(context);
    // While the role resolves, hold with a fade rather than flashing "no access".
    if (slug == null || user == null) {
      return Center(
        child: CircularProgressIndicator(color: t.colorScheme.primary),
      );
    }
    // CEO uses CEO Settings; this page is for roles below CEO only.
    if (slug == 'ceo') return const SettingsNoAccess();

    return SettingsFadeIn(
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + context.deviceBottomPadding,
        ),
        children: [
          SettingsTile(
            icon: Icons.person_rounded,
            title: 'Profile',
            subtitle: 'Edit your name and avatar',
            trailing: _chevron(context),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => EditProfileSheet(user: user, parentRef: ref),
            ),
          ),
          const SizedBox(height: 16),
          SettingsTile(
            icon: Icons.lock_rounded,
            title: 'Change PIN',
            subtitle: 'Update your unlock PIN',
            trailing: _chevron(context),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => CreatePinScreen(user: user)),
            ),
          ),
          const SizedBox(height: 16),
          SettingsTile(
            icon: Icons.brightness_6_rounded,
            title: 'Display',
            subtitle: 'Light & dark mode',
            trailing: _chevron(context),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ThemeSettingsScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chevron(BuildContext context) => Icon(
    Icons.chevron_right,
    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
  );
}
