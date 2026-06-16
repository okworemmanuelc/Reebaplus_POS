import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// [AppInput] is the standard input field for the application.
///
/// DESIGN RULE: All new input fields MUST use this widget instead of raw
/// [TextField] or [TextFormField] to maintain design consistency.
class AppInput extends StatelessWidget {
  final TextEditingController? controller;
  final String? labelText;
  final String? hintText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final String? Function(String?)? validator;
  final bool enabled;
  final int? maxLines;
  final int? minLines;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? fillColor;
  final List<TextInputFormatter>? inputFormatters;
  final bool readOnly;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? contentPadding;
  final TextAlign textAlign;
  final String? prefixText;
  final String? suffixText;
  final InputBorder? border;
  final String? initialValue;
  final TextStyle? style;

  const AppInput({
    super.key,
    this.controller,
    this.labelText,
    this.hintText,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onFieldSubmitted,
    this.validator,
    this.enabled = true,
    this.maxLines = 1,
    this.minLines,
    this.focusNode,
    this.autofocus = false,
    this.fillColor,
    this.inputFormatters,
    this.readOnly = false,
    this.onTap,
    this.contentPadding,
    this.textAlign = TextAlign.start,
    this.prefixText,
    this.suffixText,
    this.border,
    this.initialValue,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtextColor = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
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
        TextFormField(
          controller: controller,
          initialValue: initialValue,
          focusNode: focusNode,
          autofocus: autofocus,
          obscureText: obscureText,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onChanged: onChanged,
          onFieldSubmitted: onFieldSubmitted,
          validator: validator,
          enabled: enabled,
          maxLines: maxLines,
          minLines: minLines,
          inputFormatters: inputFormatters,
          readOnly: readOnly,
          onTap: onTap,
          textAlign: textAlign,
          style:
              style ??
              TextStyle(
                color: t.colorScheme.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
          decoration: InputDecoration(
            hintText: hintText,
            prefixIcon: prefixIcon,
            suffixIcon: suffixIcon,
            fillColor: fillColor ?? t.inputDecorationTheme.fillColor,
            contentPadding: contentPadding,
            prefixText: prefixText,
            suffixText: suffixText,
            border: border,
            enabledBorder: border,
            focusedBorder: border,
          ),
        ),
      ],
    );
  }
}
