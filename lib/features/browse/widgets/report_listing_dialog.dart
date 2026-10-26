// #478: Report a product or a store. Agent-designed from `ui-context.md`
// tokens and the Browse parts (no Claude Design file for it in the repo).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/shopper_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/core/storefront/shopper_session.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_sign_in_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_texts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// What the dialog hands back.
class ReportChoice {
  const ReportChoice(this.reason, this.details);
  final ReportReason reason;
  final String? details;
}

/// Asks a signed-out Shopper to sign in, then shows the reason picker and
/// sends the report. Silent if they back out; plain-words message otherwise.
Future<void> reportListing(
  BuildContext context,
  WidgetRef ref, {
  required ReportTarget target,
  required String targetId,
}) async {
  if (!ref.read(shopperSessionProvider).isSignedIn) {
    final signedIn = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ShopperSignInScreen()),
    );
    if (signedIn != true || !context.mounted) return;
  }
  final choice = await showDialog<ReportChoice>(
    context: context,
    builder: (_) => ReportListingDialog(target: target),
  );
  if (choice == null || !context.mounted) return;
  try {
    await ref.read(shopperServiceProvider).reportListing(
      target: target,
      targetId: targetId,
      reason: choice.reason,
      details: choice.details,
    );
    if (context.mounted) {
      AppNotification.showSuccess(context, 'Thanks — we will look into it');
    }
  } on ShopperException catch (e) {
    if (context.mounted) {
      AppNotification.showError(context, shopperFailureText(e.failure));
    }
  }
}

class ReportListingDialog extends StatefulWidget {
  const ReportListingDialog({super.key, required this.target});

  final ReportTarget target;

  static const maxDetails = 500;

  @override
  State<ReportListingDialog> createState() => _ReportListingDialogState();
}

class _ReportListingDialogState extends State<ReportListingDialog> {
  ReportReason? _reason;
  final _details = TextEditingController();

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final noun = widget.target == ReportTarget.store ? 'store' : 'product';
    return AlertDialog(
      scrollable: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      title: Text('Report this $noun'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('What is wrong?'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final r in ReportReason.values)
                  ChoiceChip(
                    key: Key('report-reason-${r.wire}'),
                    label: Text(r.label),
                    selected: _reason == r,
                    onSelected: (_) => setState(() => _reason = r),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('report-details'),
              controller: _details,
              maxLength: ReportListingDialog.maxDetails,
              maxLines: 3,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'More details (optional)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          isFullWidth: false,
          onPressed: () => Navigator.of(context).pop(),
        ),
        AppButton(
          key: const Key('report-send'),
          text: 'Send report',
          isFullWidth: false,
          onPressed: _reason == null
              ? null
              : () => Navigator.of(
                  context,
                ).pop(ReportChoice(_reason!, _details.text)),
        ),
      ],
    );
  }
}
