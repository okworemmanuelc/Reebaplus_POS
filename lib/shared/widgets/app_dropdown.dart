import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class AppDropdown<T> extends StatelessWidget {
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String? labelText;
  final String? hintText;
  final Widget? prefixIcon;
  final bool isExpanded;
  final double? width;
  final EdgeInsetsGeometry? contentPadding;
  final String? Function(T?)? validator;

  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.labelText,
    this.hintText,
    this.prefixIcon,
    this.isExpanded = true,
    this.width,
    this.contentPadding,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fillColor = t.cardColor;
    final textColor = t.colorScheme.onSurface;
    final subtextColor = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final dropdownColor = t.colorScheme.surface;
    final widget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (labelText != null) ...[
          Text(
            labelText!,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: subtextColor,
            ),
          ),
          const SizedBox(height: 8),
        ],
        DropdownButtonFormField<T>(
          initialValue: value,
          items: items,
          onChanged: onChanged,
          validator: validator,
          isExpanded: isExpanded,
          dropdownColor: dropdownColor,
          style: TextStyle(
            color: textColor,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          icon: Icon(
            FontAwesomeIcons.chevronDown.data,
            size: 13,
            color: subtextColor,
          ),
          selectedItemBuilder: (context) {
            return items.map((item) {
              return Container(
                alignment: Alignment.centerLeft,
                child: DefaultTextStyle(
                  style: TextStyle(
                    color: textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    overflow: TextOverflow.ellipsis,
                  ),
                  child: item.child,
                ),
              );
            }).toList();
          },
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: TextStyle(color: subtextColor, fontSize: 13),
            prefixIcon: prefixIcon,
            filled: true,
            fillColor: fillColor,
            contentPadding:
                contentPadding ??
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: t.colorScheme.primary, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Colors.red, width: 1),
            ),
          ),
        ),
      ],
    );

    if (width != null) {
      return SizedBox(width: width, child: widget);
    }
    return widget;
  }
}
