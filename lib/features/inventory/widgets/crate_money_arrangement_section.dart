import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// The **Crate Money Arrangement** picker for one manufacturer (#211, PRD #203,
/// ADR 0023 rule 3) — the owner's answer to "does money change hands for this
/// brand's crates, and when?".
///
/// Rendered inside the existing manufacturer editor on Inventory → Empty
/// Crates, which is where a brand is already managed. Two gates, both of which
/// make the section vanish entirely rather than disable it (hard rule #7):
///
/// * `businessTracksCrates` — a business that doesn't deal in crates never
///   sees the question. It is the app-wide crate-visibility gate; the business
///   *type* half of it goes through `isCrateBusiness`, never a string compare,
///   because `businesses.type` carries non-canonical casing.
/// * [Gates.crateMoneyArrangement] — a standing money policy, so only a
///   money-permitted role may set it, and the tap re-checks at fire time
///   through [Guarded]'s `allow`.
///
/// The section writes itself: choosing an arrangement confirms first (with the
/// plain-language consequence and the "your past figures do not change"
/// promise) and then persists immediately. It deliberately does NOT ride on the
/// surrounding sheet's Save button — a money policy shouldn't be able to be
/// half-chosen and then abandoned, and a confirmation that doesn't take effect
/// on OK is a confirmation nobody believes.
class CrateMoneyArrangementSection extends ConsumerStatefulWidget {
  const CrateMoneyArrangementSection({
    super.key,
    required this.manufacturer,
    this.surfaceColor,
    this.textColor,
    this.subtextColor,
  });

  /// The brand being edited. Its `crateMoneyArrangement` seeds the selection.
  final ManufacturerData manufacturer;

  /// Host sheet's surface / text colours, so the section sits in the host's
  /// palette rather than re-deriving one. Each falls back to the theme.
  final Color? surfaceColor;
  final Color? textColor;
  final Color? subtextColor;

  @override
  ConsumerState<CrateMoneyArrangementSection> createState() =>
      _CrateMoneyArrangementSectionState();
}

class _CrateMoneyArrangementSectionState
    extends ConsumerState<CrateMoneyArrangementSection> {
  late CrateMoneyArrangement _selected = crateMoneyArrangementOf(
    widget.manufacturer.crateMoneyArrangement,
  );

  Color get _text =>
      widget.textColor ?? Theme.of(context).colorScheme.onSurface;

  Color get _subtext =>
      widget.subtextColor ??
      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);

  @override
  Widget build(BuildContext context) {
    // Crate-business gate. `businessTracksCrates` is the combined check the app
    // uses everywhere for crate surfaces (crate-eligible type AND the CEO opted
    // in at onboarding); calling `isCrateBusiness` directly here would show the
    // question to a bar that turned crate tracking off.
    if (!businessTracksCrates(ref.watch(currentBusinessProvider))) {
      return const SizedBox.shrink();
    }

    return Guarded(
      gate: Gates.crateMoneyArrangement,
      builder: (context, allow) {
        return Container(
          margin: EdgeInsets.only(top: context.getRSize(16)),
          padding: EdgeInsets.all(context.getRSize(16)),
          decoration: AppDecorations.card(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const InventoryFieldLabel('CRATE MONEY'),
              SizedBox(height: context.getRSize(6)),
              Text(
                'How do you settle crates with the supplier of '
                '${widget.manufacturer.name}?',
                style: context.semiBoldStyle(14).copyWith(color: _text),
              ),
              SizedBox(height: context.getRSize(12)),
              for (final option in CrateMoneyArrangement.values)
                _option(option, allow),
              SizedBox(height: context.getRSize(4)),
              Text(
                kCrateMoneyHistoryNotice,
                style: context
                    .regularStyle(12)
                    .copyWith(height: 1.4, color: _subtext),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _option(CrateMoneyArrangement option, GateAllow allow) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = option == _selected;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(8)),
      child: InkWell(
        borderRadius: radius,
        onTap: allow(() => _choose(option)),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          padding: EdgeInsets.all(context.getRSize(12)),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: radius,
            border: Border.all(
              color: isSelected
                  ? scheme.primary
                  : Theme.of(context).dividerColor,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isSelected
                    ? AppIcons.radioButtonChecked
                    : AppIcons.radioButtonUnchecked,
                size: context.getRSize(20),
                color: isSelected ? scheme.primary : _subtext,
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: context.extraBoldStyle(14).copyWith(color: _text),
                    ),
                    SizedBox(height: context.getRSize(2)),
                    Text(
                      option.summary,
                      style: context
                          .regularStyle(12)
                          .copyWith(height: 1.35, color: _subtext),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _choose(CrateMoneyArrangement option) async {
    if (option == _selected) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.surfaceColor,
        // Scrolls rather than overflows at large text or a sideways phone.
        scrollable: true,
        title: Text(
          option.label,
          style: ctx.screenTitleStyle.copyWith(color: _text),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              option.onSwitchOn,
              style: ctx.regularStyle(14).copyWith(color: _text, height: 1.45),
            ),
            const SizedBox(height: 14),
            Text(
              kCrateMoneyHistoryNotice,
              style: ctx
                  .regularStyle(12)
                  .copyWith(height: 1.45, color: _subtext),
            ),
          ],
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Yes, use this',
            variant: AppButtonVariant.primary,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref
          .read(databaseProvider)
          .catalogDao
          .updateManufacturerCrateMoneyArrangement(
            widget.manufacturer.id,
            option,
          );
      await ref
          .read(activityLogProvider)
          .logAction(
            'update_manufacturer_crate_money',
            '${ref.read(authProvider).currentUser?.name ?? 'Unknown'} set '
                'crate money for ${widget.manufacturer.name} to '
                '"${option.label}"',
          );
      if (!mounted) return;
      setState(() => _selected = option);
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not save the crate money setting. Please try again.',
      );
    }
  }
}
