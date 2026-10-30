import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/push_messaging_port.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_page_parts.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Profile-screen tile that surfaces and manages this device's OS push
/// permission for console broadcasts (#138 Slice 2). Lives on the Profile screen
/// (ungated) so every staff member can turn announcements on for their own
/// device, or re-enable them via the OS settings after a denial.
class NotificationSettingsTile extends ConsumerStatefulWidget {
  const NotificationSettingsTile({super.key});

  @override
  ConsumerState<NotificationSettingsTile> createState() =>
      _NotificationSettingsTileState();
}

class _NotificationSettingsTileState
    extends ConsumerState<NotificationSettingsTile> {
  PushPermissionStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final status = await ref
        .read(pushNotificationServiceProvider)
        .currentPermission();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _enable() async {
    setState(() => _busy = true);
    final result = await ref
        .read(pushNotificationServiceProvider)
        .requestPermissionAndRegister();
    if (!mounted) return;
    setState(() {
      _status = result;
      _busy = false;
    });
  }

  Future<void> _openOsSettings() async {
    await openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      child: SettingsControlRow(
        icon: AppIcons.announcement,
        tone: IconTileTone.info,
        title: 'Announcements',
        subtitle: _subtitle,
        trailing: _trailing(context),
      ),
    );
  }

  String get _subtitle {
    switch (_status) {
      case PushPermissionStatus.granted:
        return 'On — important updates reach this device.';
      case PushPermissionStatus.denied:
        return 'Off — turn on in your phone settings.';
      case PushPermissionStatus.notDetermined:
        return 'Get important updates, even when the app is closed.';
      case null:
        return 'Checking…';
    }
  }

  Widget _trailing(BuildContext context) {
    if (_busy || _status == null) {
      return SizedBox(
        width: context.getRSize(18),
        height: context.getRSize(18),
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }
    switch (_status!) {
      case PushPermissionStatus.granted:
        final f =
            Theme.of(context).extension<AppFixedColors>() ??
            AppFixedColors.light;
        return AppIcon(
          AppIcons.checkCircle,
          filled: true,
          color: f.green,
          size: context.getRSize(24),
        );
      case PushPermissionStatus.notDetermined:
        return AppButton(
          text: 'Turn on',
          size: AppButtonSize.small,
          isFullWidth: false,
          onPressed: _enable,
        );
      case PushPermissionStatus.denied:
        return AppButton(
          text: 'Settings',
          variant: AppButtonVariant.outline,
          size: AppButtonSize.small,
          isFullWidth: false,
          onPressed: _openOsSettings,
        );
    }
  }
}
