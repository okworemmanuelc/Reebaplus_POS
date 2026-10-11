import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/category_chip.dart';

/// The horizontally scrolling row of category filter chips (#384: the shared
/// [CategoryChip], with its `categoryVisual` dot). [categories] are the chip
/// labels in order; the first entry named [allLabel] is the "All" chip, whose
/// dot follows its text. Every other label is also the category name its dot
/// colour comes from, so a chip matches the tint of its products' tiles.
///
/// Used by POS and Receive Stock; each passes its own labels and keeps its
/// own filter logic in [onCategorySelected].
class CategoryFilterBar extends StatelessWidget {
  final List<String> categories;
  final String selectedCategory;
  final ValueChanged<String> onCategorySelected;

  /// The label of the chip that clears the filter (no dot colour of its own).
  final String allLabel;

  const CategoryFilterBar({
    super.key,
    required this.categories,
    required this.selectedCategory,
    required this.onCategorySelected,
    this.allLabel = 'All',
  });

  @override
  Widget build(BuildContext context) {
    final gap = context.getRSize(8);
    // The chips size themselves (each keeps a 48dp tap area), so the row takes
    // their natural height rather than a fixed one that a large font would
    // clip.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
      child: Row(
        children: [
          for (var i = 0; i < categories.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            CategoryChip(
              label: categories[i],
              categoryName: categories[i] == allLabel ? null : categories[i],
              selected: categories[i] == selectedCategory,
              onTap: () => onCategorySelected(categories[i]),
            ),
          ],
        ],
      ),
    );
  }
}
