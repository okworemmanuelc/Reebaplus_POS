import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/data/marketplace_categories.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';

/// Opens the "Manage categories" bottom sheet (#109). Gate the call site with
/// [Gates.addProduct]; the rename/delete actions inside re-check it at their
/// write boundary, so a session that lost the grant mid-flow can't mutate.
Future<void> showManageCategoriesSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const ManageCategoriesSheet(),
  );
}

/// Lists the business's non-deleted categories, each with a rename (inline
/// collision guard) and a delete (soft-delete → its products move to
/// Uncategorized after a confirmation showing how many are affected). The list
/// is reactive: a rename/delete updates `watchAllCategories`, so a deleted
/// category drops out and a rename re-renders in place without a manual refresh.
class ManageCategoriesSheet extends ConsumerWidget {
  const ManageCategoriesSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final categories =
        ref.watch(allCategoriesProvider).valueOrNull ?? const <CategoryData>[];

    // The sheet's Surface, top radius and scrim come from the theme's
    // bottomSheetTheme (#392, ui-context "Bottom sheets").
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        context.getRSize(20) + context.deviceBottomPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const InventorySheetHeader(title: 'Manage categories'),
          SizedBox(height: context.getRSize(4)),
          Text(
            'Match categories for online shopping. Unmapped products appear '
            'under Other and still sell at the till.',
            style: context.regularStyle(13).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(16)),
          if (categories.isEmpty)
            const InventoryEmptyCard(
              icon: AppIcons.tag,
              title: 'No categories yet. Add one while creating a product.',
            )
          else
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: context.sheetMaxHeight(0.5),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: categories.length,
                  separatorBuilder: (_, __) =>
                      SizedBox(height: context.getRSize(8)),
                  itemBuilder: (_, i) => _CategoryRow(category: categories[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One category row: a flat card with the category's tile, name, rename and
/// delete. A [ConsumerWidget] so each action can re-check [Gates.addProduct]
/// at its write boundary and reach the DAO.
class _CategoryRow extends ConsumerWidget {
  const _CategoryRow({required this.category});

  final CategoryData category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final visual = categoryVisual(category.name, f);
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          context.getRSize(12),
          context.getRSize(6),
          context.getRSize(4),
          context.getRSize(6),
        ),
        child: Row(
          children: [
            IconTile(
              icon: visual.icon,
              tint: visual.tint,
              iconColor: visual.iconColor,
              size: 40,
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(category.name, maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.boldStyle(15)
                        .copyWith(color: t.colorScheme.onSurface)),
                  if (Gates.addProduct.allows(ref))
                    AppDropdown<String>(
                      key: ValueKey('marketplace-${category.id}'),
                      labelText: 'Online category',
                      value: marketplaceCategoryFor(
                          category.marketplaceCategory).slug,
                      items: [
                        for (final c in marketplaceCategories)
                          DropdownMenuItem(value: c.slug,
                            child: Text(c.parentSlug == null ? c.name
                              : '${marketplaceCategoryFor(c.parentSlug).name} / ${c.name}',
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (slug) async {
                        if (!Gates.addProduct.allowsNow(ref)) return;
                        try {
                          await ref.read(databaseProvider).catalogDao
                              .mapCategory(category.id, slug == 'other' ? null : slug);
                        } catch (_) {
                          if (context.mounted) {
                            AppNotification.showError(context,
                                'Could not update the online category.');
                          }
                        }
                      },
                    ),
                ],
              ),
            ),
            _RowAction(
              icon: AppIcons.edit,
              tooltip: 'Rename',
              color: t.colorScheme.primary,
              onTap: () => _rename(context, ref, category),
            ),
            _RowAction(
              icon: AppIcons.delete,
              tooltip: 'Delete',
              color: f.danger,
              onTap: () => _confirmDelete(context, ref, category),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: AppIcon(icon, size: context.getRSize(20), color: color),
      // A 48dp target at every scale (#392; it compacted to ~34dp before).
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
    );
  }
}

/// Rename dialog with an inline collision guard (#109 AC #1). A case-only edit
/// of the category's own name is allowed (it excludes itself); any other name
/// already used by a live category is rejected in place.
Future<void> _rename(
  BuildContext context,
  WidgetRef ref,
  CategoryData category,
) async {
  final controller = TextEditingController(text: category.name);
  String? errorText;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        // Scrolls rather than overflows over a sideways keyboard (#392).
        scrollable: true,
        title: Text(
          'Rename category',
          style: ctx.screenTitleStyle.copyWith(
            color: Theme.of(ctx).colorScheme.onSurface,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppInput(
              controller: controller,
              labelText: 'Category name',
              autofocus: true,
              onChanged: (_) {
                if (errorText != null) setLocal(() => errorText = null);
              },
            ),
            if (errorText != null) ...[
              SizedBox(height: ctx.getRSize(8)),
              Text(
                errorText!,
                style: ctx
                    .mediumStyle(12)
                    .copyWith(
                      color:
                          (Theme.of(ctx).extension<AppFixedColors>() ??
                                  AppFixedColors.light)
                              .danger,
                    ),
              ),
            ],
          ],
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx),
          ),
          AppButton(
            text: 'Save',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.small,
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                setLocal(() => errorText = 'Enter a name.');
                return;
              }
              if (name == category.name) {
                Navigator.pop(ctx); // no-op
                return;
              }
              // Write boundary: re-check the grant before mutating.
              if (!Gates.addProduct.allowsNow(ref)) {
                Navigator.pop(ctx);
                return;
              }
              final db = ref.read(databaseProvider);
              final collides = await db.catalogDao.categoryNameExists(
                name,
                excludeId: category.id,
              );
              if (collides) {
                setLocal(
                  () => errorText = 'A category named "$name" already exists.',
                );
                return;
              }
              try {
                await db.catalogDao.renameCategory(category.id, name: name);
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (_) {
                if (ctx.mounted) {
                  AppNotification.showError(
                    ctx,
                    'Could not rename the category. Please try again.',
                  );
                }
              }
            },
          ),
        ],
      ),
    ),
  );
}

/// Delete confirmation (#109 AC #2/#3): shows how many products will move to
/// Uncategorized, then soft-deletes the category and reassigns them on confirm.
Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  CategoryData category,
) async {
  final db = ref.read(databaseProvider);
  final count = await db.catalogDao.countProductsInCategory(category.id);
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final tint =
          theme.extension<AppSchemeColors>()?.primaryTint ??
          theme.colorScheme.primary.withValues(alpha: 0.12);
      return AlertDialog(
        // Scrolls rather than overflows over a sideways keyboard (#392).
        scrollable: true,
        title: Text(
          'Delete category',
          style: ctx.screenTitleStyle.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Delete "${category.name}"?',
              style: ctx
                  .mediumStyle(14)
                  .copyWith(color: theme.colorScheme.onSurface),
            ),
            SizedBox(height: ctx.getRSize(12)),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: ctx.getRSize(12),
                vertical: ctx.getRSize(10),
              ),
              decoration: BoxDecoration(
                color: tint,
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
              ),
              child: Text(
                count == 0
                    ? 'No products are in this category.'
                    : 'This will move $count '
                          '${count == 1 ? 'product' : 'products'} to '
                          'Uncategorized. Nothing is deleted from your catalogue.',
                style: ctx
                    .semiBoldStyle(13)
                    .copyWith(color: theme.colorScheme.primary),
              ),
            ),
          ],
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx),
          ),
          AppButton(
            text: 'Delete',
            variant: AppButtonVariant.danger,
            size: AppButtonSize.small,
            onPressed: () async {
              Navigator.pop(ctx);
              // Write boundary: re-check the grant before mutating.
              if (!Gates.addProduct.allowsNow(ref)) return;
              // Success feedback is the row vanishing from the reactive list;
              // the confirmation above already stated the "move to Uncategorized"
              // consequence, so no redundant toast (and the row's context is
              // unmounted by the delete, which would silently no-op one anyway).
              try {
                await db.catalogDao.softDeleteCategoryAndReassign(category.id);
              } catch (_) {
                if (context.mounted) {
                  AppNotification.showError(
                    context,
                    'Could not delete the category. Please try again.',
                  );
                }
              }
            },
          ),
        ],
      );
    },
  );
}
