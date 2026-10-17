import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/receipt_printer_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/settings_page_parts.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/theme_settings_screen.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/profile/widgets/edit_profile_sheet.dart';

/// Staff Settings (§10.5) — the self-service settings home for roles **below
/// CEO** (Manager, Cashier, Stock keeper). Personal, not business-wide: edit
/// own name/avatar, change the unlock PIN, and pick the per-device Display mode
/// (moved here from the side menu for these roles). The CEO never sees this —
/// they use CEO Settings. Role-gated here as defense-in-depth (hard rule #6);
/// the drawer already hides it for the CEO.
///
/// Restyled in #442 (PRD #346 Wave 2 C): the CEO Settings menu's look — solid
/// top bar, [SettingsRow]s, content capped at 720dp.
class StaffSettingsScreen extends ConsumerWidget {
  const StaffSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).currentUser;
    final slug = ref.watch(currentUserRoleProvider)?.slug;

    return SettingsPageScaffold(
      icon: AppIcons.settings,
      title: 'Settings',
      body: _buildBody(context, ref, user, slug),
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

    final gap = SizedBox(height: context.getRSize(12));
    return SettingsFadeIn(
      child: SettingsPageList(
        listKey: const Key('staff-settings-list'),
        children: [
          SettingsRow(
            icon: AppIcons.user,
            tone: IconTileTone.info,
            title: 'Profile',
            subtitle: 'Edit your name and avatar',
            onTap: () =>
                EditProfileSheet.show(context, user: user, parentRef: ref),
          ),
          gap,
          SettingsRow(
            icon: AppIcons.lock,
            tone: IconTileTone.danger,
            title: 'Change PIN',
            subtitle: 'Update your unlock PIN',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => CreatePinScreen(user: user)),
            ),
          ),
          gap,
          SettingsRow(
            icon: AppIcons.print,
            tone: IconTileTone.neutral,
            title: 'Receipt printer',
            subtitle: 'Paper size for each printer (58mm or 80mm)',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const ReceiptPrinterSettingsScreen(),
              ),
            ),
          ),
          gap,
          SettingsRow(
            icon: AppIcons.themeMode,
            tone: IconTileTone.info,
            title: 'Display',
            subtitle: 'Light & dark mode',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ThemeSettingsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
