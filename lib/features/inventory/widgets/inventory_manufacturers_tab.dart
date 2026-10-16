import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/first_download_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/add_manufacturer_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Key prefix for one manufacturer row on the Manufacturers tab (#389).
const String kInventoryManufacturerRowKeyPrefix = 'inventory_manufacturer_row_';

/// Inventory → Manufacturers (#389): EVERY manufacturer in the business, bottle
/// or not, each opening the existing [ManufacturerScreen]. Empty Crates lists
/// only the brands that have returnable bottles, so this tab is where a can /
/// PET / pack brand — or a brand-new one with no products yet — is reached and
/// where a manufacturer is added. A sliver: it sits in the tab's own scroll view.
class InventoryManufacturersTab extends ConsumerWidget {
  const InventoryManufacturersTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manufacturers =
        ref.watch(allManufacturersProvider).valueOrNull ??
        const <ManufacturerData>[];
    final trackedIds =
        ref.watch(crateTrackedManufacturerIdsProvider).valueOrNull ??
        const <String>{};
    final isFirstDownload = ref.watch(firstDownloadInProgressProvider);
    final canAdd = Gates.addManufacturer.allows(ref);
    final gap = context.getRSize(12);

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // Settings-style list: capped at 720dp and centred on wide screens.
        final gutter = inventoryGutter(context, constraints.crossAxisExtent);
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            context.getRSize(16),
            gutter,
            context.getRSize(120) + context.deviceBottomPadding,
          ),
          sliver: SliverList.list(
            children: [
              Row(
                children: [
                  Expanded(
                    child: SectionHeader(
                      title: 'Manufacturers',
                      subtitle: manufacturers.isEmpty
                          ? null
                          : _countLabel(manufacturers.length),
                    ),
                  ),
                  if (canAdd)
                    AppButton(
                      text: 'Add New',
                      icon: AppIcons.addCircle,
                      variant: AppButtonVariant.ghost,
                      isFullWidth: false,
                      onPressed: () => AddManufacturerSheet.show(
                        context,
                        existingNames: [for (final m in manufacturers) m.name],
                      ),
                    ),
                ],
              ),
              SizedBox(height: gap),
              // No "none yet" before the first download has finished (#313).
              if (manufacturers.isEmpty && !isFirstDownload)
                _NoManufacturers(canAdd: canAdd),
              for (final mfr in manufacturers) ...[
                SettingsRow(
                  key: ValueKey('$kInventoryManufacturerRowKeyPrefix${mfr.id}'),
                  icon: AppIcons.manufacturer,
                  tone: trackedIds.contains(mfr.id)
                      ? IconTileTone.info
                      : IconTileTone.neutral,
                  title: mfr.name,
                  subtitle: _subtitle(
                    hasBottles: trackedIds.contains(mfr.id),
                    crateValueKobo: mfr.depositAmountKobo,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ManufacturerScreen(manufacturer: mfr),
                    ),
                  ),
                ),
                SizedBox(height: gap),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _countLabel(int count) =>
      count == 1 ? '1 manufacturer' : '$count manufacturers';

  /// Bottle brands show their crate value; the rest say why they are not on
  /// Empty Crates.
  static String _subtitle({
    required bool hasBottles,
    required int crateValueKobo,
  }) {
    if (!hasBottles) return 'No returnable bottles';
    if (crateValueKobo <= 0) return 'Returnable bottles';
    return 'Returnable bottles · Crate value '
        '${formatCurrency(crateValueKobo / 100)}';
  }
}

class _NoManufacturers extends StatelessWidget {
  const _NoManufacturers({required this.canAdd});

  final bool canAdd;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(28)),
      child: Column(
        children: [
          AppIcon(
            AppIcons.manufacturer,
            size: context.getRSize(32),
            color: muted,
          ),
          SizedBox(height: context.getRSize(12)),
          Text(
            'No manufacturers yet',
            textAlign: TextAlign.center,
            style: context
                .boldStyle(16)
                .copyWith(color: t.colorScheme.onSurface),
          ),
          if (canAdd)
            Text(
              'Tap Add New to add your first manufacturer',
              textAlign: TextAlign.center,
              style: context.regularStyle(13).copyWith(color: muted),
            ),
        ],
      ),
    );
  }
}
