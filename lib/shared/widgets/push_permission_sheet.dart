import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/push_messaging_port.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Once-per-install SharedPreferences flag so the soft-ask never nags.
const String _kSoftAskShownKey = 'push_soft_ask_shown_v1';

/// Show the brand-styled soft-ask **once per install**, and only when the OS
/// permission has never been asked. Granted devices are already registered
/// (on sign-in); denied devices are respected (the Settings → Notifications
/// toggle re-enables them) — neither is nagged. On "Turn on" it triggers the OS
/// prompt and registers the token (#138 Slice 2).
Future<void> maybePromptForPushPermission(
  BuildContext context,
  WidgetRef ref,
) async {
  final push = ref.read(pushNotificationServiceProvider);
  final status = await push.currentPermission();
  if (status != PushPermissionStatus.notDetermined) return;

  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kSoftAskShownKey) ?? false) return;
  await prefs.setBool(_kSoftAskShownKey, true);

  if (!context.mounted) return;
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const PushPermissionSheet(),
  );
  if (accepted == true) {
    await push.requestPermissionAndRegister();
  }
}

/// The soft-ask bottom sheet — explains the value of announcements before the
/// OS permission prompt. Returns `true` (Turn on) / `false` (Not now) via
/// `Navigator.pop`.
class PushPermissionSheet extends StatelessWidget {
  const PushPermissionSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            context.getRSize(24),
            context.getRSize(12),
            context.getRSize(24),
            context.getRSize(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: context.getRSize(40),
                  height: context.getRSize(4),
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              SizedBox(height: context.getRSize(24)),
              Container(
                width: context.getRSize(56),
                height: context.getRSize(56),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  FontAwesomeIcons.bullhorn.data,
                  color: theme.colorScheme.primary,
                  size: context.getRSize(24),
                ),
              ),
              SizedBox(height: context.getRSize(20)),
              Text(
                'Turn on announcements',
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: context.getRFontSize(20),
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: context.getRSize(10)),
              Text(
                'Get important updates from your team on this device — even '
                'when the app is closed. You can turn this off anytime in '
                'Settings.',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: context.getRFontSize(14),
                  height: 1.4,
                ),
              ),
              SizedBox(height: context.getRSize(28)),
              AppButton(
                text: 'Turn on',
                icon: FontAwesomeIcons.bell.data,
                onPressed: () => Navigator.pop(context, true),
              ),
              SizedBox(height: context.getRSize(8)),
              AppButton(
                text: 'Not now',
                variant: AppButtonVariant.ghost,
                onPressed: () => Navigator.pop(context, false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
