import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/staff/screens/invite_staff_screen.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_constants.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Centred thank-you pop-up shown right after a user-started purchase or
/// upgrade is verified (#590). Nothing about it is stored.
Future<void> showThankYouDialog(
  BuildContext context, {
  required String businessName,
  required PlanTier tier,
  required BillingCycle cycle,
  required String price,
  DateTime? renewsOn,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ThankYouDialog(
      businessName: businessName,
      tier: tier,
      cycle: cycle,
      price: price,
      renewsOn: renewsOn,
    ),
  );
}

class ThankYouDialog extends StatefulWidget {
  const ThankYouDialog({
    super.key,
    required this.businessName,
    required this.tier,
    required this.cycle,
    required this.price,
    this.renewsOn,
  });

  final String businessName;
  final PlanTier tier;
  final BillingCycle cycle;
  final String price;
  final DateTime? renewsOn;

  @override
  State<ThankYouDialog> createState() => _ThankYouDialogState();
}

class _ThankYouDialogState extends State<ThankYouDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat(reverse: true);
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 1.15)
      .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  List<String> get _perks => widget.tier == PlanTier.basic
      ? const ['Up to 5 staff']
      : const ['Unlimited shops', 'Unlimited staff', 'Warehouse'];

  void _addStaff() {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute<void>(builder: (_) => const InviteStaffScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fixed = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final planName = widget.tier == PlanTier.basic ? 'Basic' : 'Premium';
    final per = widget.cycle == BillingCycle.monthly ? 'month' : 'year';
    final renews = widget.renewsOn == null
        ? ''
        : ' · Renews ${DateFormat('d MMM').format(widget.renewsOn!.toLocal())}';
    final ring = context.getRSize(110);

    return Dialog(
      key: const Key('thank-you-dialog'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(context.getRSize(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: SizedBox(
                  width: context.getRSize(120),
                  height: context.getRSize(120),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _scale,
                        builder: (context, _) => Transform.scale(
                          scale: _scale.value,
                          child: Container(
                            width: ring,
                            height: ring,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: fixed.green.withValues(alpha: 0.25),
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const IconTile(
                        icon: AppIcons.premium,
                        tone: IconTileTone.green,
                        size: 88,
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: context.getRSize(12)),
              Text(
                'Thank you for subscribing!',
                textAlign: TextAlign.center,
                style: context
                    .extraBoldStyle(22)
                    .copyWith(color: theme.colorScheme.onSurface),
              ),
              SizedBox(height: context.getRSize(8)),
              Text(
                '${widget.businessName} is now on $planName.',
                key: const Key('thank-you-plan-line'),
                textAlign: TextAlign.center,
                style: context.regularStyle(15).copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.4),
              ),
              SizedBox(height: context.getRSize(16)),
              for (final perk in _perks)
                Padding(
                  padding: EdgeInsets.only(bottom: context.getRSize(6)),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: fixed.green, size: 20),
                      SizedBox(width: context.getRSize(10)),
                      Expanded(
                        child: Text(perk, style: context.boldStyle(14)),
                      ),
                    ],
                  ),
                ),
              SizedBox(height: context.getRSize(8)),
              Text(
                '${widget.price} / $per$renews',
                key: const Key('thank-you-price-line'),
                textAlign: TextAlign.center,
                style: context.regularStyle(13).copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              SizedBox(height: context.getRSize(16)),
              AppButton(
                key: const Key('thank-you-add-staff'),
                text: 'Add staff',
                onPressed: _addStaff,
              ),
              TextButton(
                key: const Key('thank-you-done'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
