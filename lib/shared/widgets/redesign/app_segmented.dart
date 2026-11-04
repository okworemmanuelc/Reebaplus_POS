import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// A choice between a few short options: a Surface 2 track with the chosen
/// item raised on a surface tile, or, with [solid], filled primary. Used by
/// Payroll and Settings > Receipt printer.
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.solid = false,
    this.unselectedColor,
    this.keyOf,
  });

  /// The chosen item; null shows nothing chosen yet.
  final T? value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final bool solid;

  /// The label colour of items not chosen. Muted by default.
  final Color? unselectedColor;

  /// A key for each item (tests).
  final Key Function(T item)? keyOf;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final track = t.inputDecorationTheme.fillColor ?? t.dividerColor;
    final shadow = t.extension<AppSchemeColors>()?.cardShadow;
    final unselected =
        unselectedColor ??
        t.textTheme.bodySmall?.color ??
        t.colorScheme.onSurface;
    return Container(
      padding: EdgeInsets.all(context.getRSize(4)),
      decoration: BoxDecoration(
        color: track,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items.entries)
            Expanded(
              child: Semantics(
                button: true,
                selected: item.key == value,
                child: GestureDetector(
                  key: keyOf?.call(item.key),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(item.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    constraints: const BoxConstraints(
                      minHeight: kMinInteractiveDimension - 4,
                    ),
                    alignment: Alignment.center,
                    padding: EdgeInsets.symmetric(
                      horizontal: context.getRSize(6),
                    ),
                    decoration: BoxDecoration(
                      color: item.key != value
                          ? null
                          : (solid
                                ? t.colorScheme.primary
                                : t.colorScheme.surface),
                      borderRadius: BorderRadius.circular(
                        AppSpacing.borderRadiusM,
                      ),
                      boxShadow: item.key == value && !solid && shadow != null
                          ? [BoxShadow(color: shadow, blurRadius: 6)]
                          : null,
                    ),
                    child: Text(
                      item.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context
                          .boldStyle(14)
                          .copyWith(
                            color: item.key != value
                                ? unselected
                                : (solid
                                      ? t.colorScheme.onPrimary
                                      : t.colorScheme.onSurface),
                          ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
