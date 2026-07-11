import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Opens the "Manage categories" bottom sheet (#109). Gate the call site with
/// [Gates.addProduct]; the rename/delete actions inside re-check it at their
/// write boundary, so a session that lost the grant mid-flow can't mutate.
Future<void> showManageCategoriesSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
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
    final theme = Theme.of(context);
    final categories =
        ref.watch(allCategoriesProvider).valueOrNull ?? const <CategoryData>[];

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
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
          SizedBox(height: context.getRSize(16)),
          Text('Manage categories', style: theme.textTheme.titleLarge),
          SizedBox(height: context.getRSize(4)),
          Text(
            'Rename a category, or delete it to move its products to '
            'Uncategorized.',
            style: theme.textTheme.bodySmall,
          ),
          SizedBox(height: context.getRSize(16)),
          if (categories.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.getRSize(28)),
              child: Center(
                child: Text(
                  'No categories yet. Add one while creating a product.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: categories.length,
                  separatorBuilder: (_, __) => Divider(
                    height: context.getRSize(1),
                    color: theme.dividerColor,
                  ),
                  itemBuilder: (_, i) =>
                      _CategoryRow(category: categories[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One category row: name + rename + delete. A [ConsumerWidget] so each action
/// can re-check [Gates.addProduct] at its write boundary and reach the DAO.
class _CategoryRow extends ConsumerWidget {
  const _CategoryRow({required this.category});

  final CategoryData category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(6)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              category.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
          _RowAction(
            icon: FontAwesomeIcons.penToSquare.data,
            tooltip: 'Rename',
            color: theme.colorScheme.primary,
            onTap: () => _rename(context, ref, category),
          ),
          SizedBox(width: context.getRSize(4)),
          _RowAction(
            icon: FontAwesomeIcons.trashCan.data,
            tooltip: 'Delete',
            color: theme.colorScheme.error,
            onTap: () => _confirmDelete(context, ref, category),
          ),
        ],
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
      icon: Icon(icon, size: context.getRSize(16), color: color),
      splashRadius: context.getRSize(20),
      constraints: BoxConstraints(
        minWidth: context.getRSize(40),
        minHeight: context.getRSize(40),
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
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          'Rename category',
          style: Theme.of(ctx).textTheme.titleLarge,
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
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.error,
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
      return AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text('Delete category', style: theme.textTheme.titleLarge),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Delete "${category.name}"?',
              style: theme.textTheme.bodyMedium,
            ),
            SizedBox(height: ctx.getRSize(12)),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: ctx.getRSize(12),
                vertical: ctx.getRSize(10),
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.25),
                ),
              ),
              child: Text(
                count == 0
                    ? 'No products are in this category.'
                    : 'This will move $count '
                          '${count == 1 ? 'product' : 'products'} to '
                          'Uncategorized. Nothing is deleted from your catalogue.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
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
