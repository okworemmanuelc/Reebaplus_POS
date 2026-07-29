import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
        final scheme = Theme.of(context).colorScheme;
        return Container(
          margin: const EdgeInsets.only(top: 20),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CRATE MONEY',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'How do you settle crates with the supplier of '
                '${widget.manufacturer.name}?',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _text,
                ),
              ),
              const SizedBox(height: 12),
              for (final option in CrateMoneyArrangement.values)
                _option(option, allow),
              const SizedBox(height: 4),
              Text(
                kCrateMoneyHistoryNotice,
                style: TextStyle(fontSize: 11, height: 1.4, color: _subtext),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: allow(() => _choose(option)),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.12),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: isSelected ? scheme.primary : _subtext,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: _text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      option.summary,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: _subtext,
                      ),
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
        title: Text(option.label, style: TextStyle(color: _text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              option.onSwitchOn,
              style: TextStyle(color: _text, height: 1.45),
            ),
            const SizedBox(height: 14),
            Text(
              kCrateMoneyHistoryNotice,
              style: TextStyle(fontSize: 12, height: 1.45, color: _subtext),
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
