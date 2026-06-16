import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class CategoryFilterBar extends StatelessWidget {
  final List<String> categories;
  final String selectedCategory;
  final Function(String) onCategorySelected;
  final Color textCol;
  final Color borderCol;

  const CategoryFilterBar({
    super.key,
    required this.categories,
    required this.selectedCategory,
    required this.onCategorySelected,
    required this.textCol,
    required this.borderCol,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: context.getRSize(38),
      margin: EdgeInsets.only(
        top: context.getRSize(8),
        bottom: context.getRSize(16),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
        itemCount: categories.length,
        separatorBuilder: (context, index) =>
            SizedBox(width: context.getRSize(10)),
        itemBuilder: (context, index) {
          final category = categories[index];
          final isSelected = category == selectedCategory;
          return _CategoryChip(
            label: category,
            isSelected: isSelected,
            onTap: () => onCategorySelected(category),
            textCol: textCol,
            borderCol: borderCol,
          );
        },
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final Color textCol;
  final Color borderCol;

  const _CategoryChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.textCol,
    required this.borderCol,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(25),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(16),
          vertical: context.getRSize(6),
        ),
        decoration: BoxDecoration(
          color: isSelected ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(25),
          border: Border.all(
            color: isSelected ? scheme.primary : borderCol,
            width: 1.5,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
              color: isSelected ? scheme.onPrimary : textCol,
            ),
          ),
        ),
      ),
    );
  }
}
