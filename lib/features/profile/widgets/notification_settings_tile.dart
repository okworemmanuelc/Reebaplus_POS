import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/push_messaging_port.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';

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
    final status =
        await ref.read(pushNotificationServiceProvider).currentPermission();
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
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final subtext =
        theme.textTheme.bodySmall?.color ?? theme.iconTheme.color!;

    return GlassyCard(
      padding: EdgeInsets.all(context.getRSize(16)),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(context.getRSize(10)),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              FontAwesomeIcons.bullhorn.data,
              color: primary,
              size: context.getRSize(16),
            ),
          ),
          SizedBox(width: context.getRSize(14)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Announcements',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: context.getRFontSize(14),
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  _subtitle,
                  style: TextStyle(
                    color: subtext,
                    fontSize: context.getRFontSize(12),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          _trailing(context),
        ],
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
        final success =
            Theme.of(context).extension<AppSemanticColors>()?.success ??
                Theme.of(context).colorScheme.primary;
        return Icon(
          FontAwesomeIcons.circleCheck.data,
          color: success,
          size: context.getRSize(18),
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
