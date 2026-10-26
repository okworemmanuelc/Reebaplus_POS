import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/shopper_age_confirmation.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// The 18+ gate (#479). Call before an age-restricted item
/// (`StorefrontCard.ageRestricted`) first enters the cart. Returns true when
/// the Shopper has confirmed (now or before); false when they declined.
///
/// Asks once per phone; the answer is remembered by
/// [shopperAgeConfirmationProvider] and copied to the Shopper's login.
Future<bool> ensureShopperAgeConfirmed(BuildContext context, WidgetRef ref) async {
  final notifier = ref.read(shopperAgeConfirmationProvider.notifier);
  if (await ref.read(shopperAgeConfirmationProvider.future)) return true;
  if (!context.mounted) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => const AgeConfirmationDialog(),
  );
  if (confirmed != true) return false;
  await notifier.confirm();
  return true;
}

/// "Are you 18 or older?" — agent-designed from `ui-context.md` tokens and the
/// Browse parts (no Claude Design file for it in the repo).
class AgeConfirmationDialog extends StatelessWidget {
  const AgeConfirmationDialog({super.key});

  static const title = 'Are you 18 or older?';
  static const body =
      'This item contains alcohol. Only people aged 18 or older may buy it. '
      'We ask once on this phone.';
  static const confirmLabel = 'I am 18 or older';
  static const declineLabel = 'Not now';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return AlertDialog(
      scrollable: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconTile(
                  icon: AppIcons.userVerified,
                  tone: IconTileTone.danger,
                  size: context.getRSize(48),
                ),
                SizedBox(width: context.getRSize(10)),
                const TagPill(label: '18+', tone: TagPillTone.danger),
              ],
            ),
            SizedBox(height: context.getRSize(14)),
            Text(
              title,
              textAlign: TextAlign.center,
              style: context
                  .extraBoldStyle(17)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              body,
              textAlign: TextAlign.center,
              style: context.regularStyle(14).copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(18)),
            AppButton(
              key: const ValueKey('age-confirm'),
              text: confirmLabel,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            SizedBox(height: context.getRSize(8)),
            AppButton(
              key: const ValueKey('age-decline'),
              text: declineLabel,
              variant: AppButtonVariant.outline,
              onPressed: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
  }
}
