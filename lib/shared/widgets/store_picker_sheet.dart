import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

/// §12.1 store picker bottom sheet — the single shared active-store control used
/// by both the nav drawer and the POS "select a store" gate. Selecting a store
/// sets the global active store (`lockedStoreId`), which every store-scoped view
/// (Home / Inventory / POS / Customers / Activity Log) reflects. [onSelected]
/// runs after a pick (e.g. the drawer closes itself); it does NOT run when the
/// user dismisses the sheet without choosing.
Future<void> showStorePickerSheet(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onSelected,
}) {
  final selectable = ref.read(selectableStoresProvider);
  final canViewAll = ref.read(canViewAllStoresProvider);
  final activeId = ref.read(lockedStoreProvider).value;

  final t = Theme.of(context);
  final primary = t.colorScheme.primary;
  final textColor = t.colorScheme.onSurface;
  final subtextColor = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

  final options = <({String? id, String name})>[
    if (canViewAll) (id: null, name: 'All Stores'),
    ...selectable.map((s) => (id: s.id, name: s.name)),
  ];

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) {
      return Padding(
        padding: EdgeInsets.only(
          top: context.getRSize(8),
          bottom: context.deviceBottomPadding + context.getRSize(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: context.getRSize(40),
              height: context.getRSize(4),
              margin: EdgeInsets.only(bottom: context.getRSize(12)),
              decoration: BoxDecoration(
                color: subtextColor.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
              child: Row(
                children: [
                  Text(
                    'Select Store',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(16),
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.getRSize(8)),
            ...options.map((o) {
              final selected = o.id == activeId;
              return InkWell(
                onTap: () {
                  ref.read(navigationProvider).setLockedStore(o.id);
                  Navigator.of(sheetCtx).pop();
                  onSelected?.call();
                },
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(20),
                    vertical: context.getRSize(14),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        o.id == null
                            ? FontAwesomeIcons.layerGroup.data
                            : FontAwesomeIcons.store.data,
                        size: context.getRSize(15),
                        color: selected ? primary : subtextColor,
                      ),
                      SizedBox(width: context.getRSize(14)),
                      Expanded(
                        child: Text(
                          o.name,
                          style: TextStyle(
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.w600,
                            fontSize: context.getRFontSize(14.5),
                            color: selected ? primary : textColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (selected)
                        Icon(
                          FontAwesomeIcons.check.data,
                          size: context.getRSize(14),
                          color: primary,
                        ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      );
    },
  );
}
