import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class ViewSelectorSheet extends StatelessWidget {
  final bool currentIsList;
  final int currentColumns;
  final void Function(bool isList, int columns) onSelect;

  const ViewSelectorSheet({
    super.key,
    required this.currentIsList,
    required this.currentColumns,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final surfaceCol = Theme.of(context).colorScheme.surface;
    final textCol = Theme.of(context).colorScheme.onSurface;
    final screenWidth = MediaQuery.of(context).size.width;

    return Container(
      decoration: BoxDecoration(
        color: surfaceCol,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: context.deviceBottomPadding + context.getRSize(24),
        top: context.getRSize(16),
        left: context.getRSize(16),
        right: context.getRSize(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          SizedBox(height: context.getRSize(24)),
          Text(
            'Select View Layout',
            style: TextStyle(
              fontSize: context.getRFontSize(18),
              fontWeight: FontWeight.bold,
              color: textCol,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: context.getRSize(24)),
          _buildOption(
            context: context,
            icon: FontAwesomeIcons.list.data,
            label: 'List View',
            isSelected: currentIsList,
            onTap: () => onSelect(true, currentColumns),
          ),
          SizedBox(height: context.getRSize(12)),
          _buildOption(
            context: context,
            icon: FontAwesomeIcons.tableCellsLarge.data,
            label: '2 Columns Grid',
            isSelected: !currentIsList && currentColumns == 2,
            onTap: () => onSelect(false, 2),
          ),
          if (screenWidth >= 380) ...[
            SizedBox(height: context.getRSize(12)),
            _buildOption(
              context: context,
              icon: FontAwesomeIcons.tableCells.data,
              label: '3 Columns Grid',
              isSelected: !currentIsList && currentColumns == 3,
              onTap: () => onSelect(false, 3),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOption({
    required BuildContext context,
    required IconData? icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final primaryCol = Theme.of(context).colorScheme.primary;
    final textCol = Theme.of(context).colorScheme.onSurface;
    final surfaceCol = Theme.of(context).colorScheme.surface;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(16),
          vertical: context.getRSize(16),
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? primaryCol.withValues(alpha: 0.1)
              : surfaceCol,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? primaryCol.withValues(alpha: 0.3)
                : Theme.of(context).dividerColor,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: context.getRSize(20),
              color: isSelected
                  ? primaryCol
                  : textCol.withValues(alpha: 0.6),
            ),
            SizedBox(width: context.getRSize(16)),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: context.getRFontSize(16),
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                  color: isSelected ? primaryCol : textCol,
                ),
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle_rounded,
                size: context.getRSize(20),
                color: primaryCol,
              ),
          ],
        ),
      ),
    );
  }
}
