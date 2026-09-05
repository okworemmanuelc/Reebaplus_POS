import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';

/// [AppInput] is the standard input field for the application.
///
/// DESIGN RULE: All new input fields MUST use this widget instead of raw
/// [TextField] or [TextFormField] to maintain design consistency.
///
/// ### Responsive Sizing & Icon Constraints
/// In short viewports (`context.isShortViewport` is true, e.g. landscape phones),
/// [AppInput] renders at a compact target height of 40dp (down from 53dp in
/// comfortable portrait) by applying `isDense: true` and compact content padding.
///
/// - **Decorative icons:** Purely decorative icons (such as search indicators or
///   currency badges) automatically receive compact 40×40 constraints
///   ([prefixIconConstraints] / [suffixIconConstraints]), allowing the field to
///   meet its 40dp height target.
/// - **Interactive icons:** Interactive controls (e.g. [GestureDetector], [IconButton],
///   [TextButton], [InkWell], even when nested inside [Padding], [SizedBox], or
///   [Center]) preserve Flutter's default 48×48 minimum tap target floor. If a field
///   contains both a decorative and an interactive icon, the interactive one wins
///   and the entire field remains at 48dp.
/// - **Explicit constraints:** Any caller-supplied [prefixIconConstraints] or
///   [suffixIconConstraints] always take precedence over these defaults.
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
  final BoxConstraints? prefixIconConstraints;
  final BoxConstraints? suffixIconConstraints;

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
    this.prefixIconConstraints,
    this.suffixIconConstraints,
  });

  /// Unwraps common single-child wrapper widgets to reveal the core icon/control.
  static Widget? _unwrap(Widget? widget) {
    var current = widget;
    while (current != null) {
      if (current is Padding) {
        current = current.child;
      } else if (current is SizedBox) {
        current = current.child;
      } else if (current is Align) {
        current = current.child;
      } else if (current is Center) {
        current = current.child;
      } else if (current is Container) {
        current = current.child;
      } else if (current is DecoratedBox) {
        current = current.child;
      } else if (current is ConstrainedBox) {
        current = current.child;
      } else if (current is FittedBox) {
        current = current.child;
      } else if (current is Opacity) {
        current = current.child;
      } else if (current is Transform) {
        current = current.child;
      } else {
        break;
      }
    }
    return current;
  }

  static bool _isInteractive(Widget? widget) {
    final core = _unwrap(widget);
    if (core == null) return false;
    return core is IconButton ||
        core is TextButton ||
        core is ElevatedButton ||
        core is OutlinedButton ||
        core is GestureDetector ||
        core is InkWell ||
        core is InkResponse;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtextColor = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    final bool hasInteractiveIcon =
        _isInteractive(prefixIcon) || _isInteractive(suffixIcon);

    final BoxConstraints? compactConstraints =
        (context.isShortViewport && !hasInteractiveIcon)
            ? const BoxConstraints(minWidth: 40, minHeight: 40)
            : null;

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
            prefixIconConstraints:
                prefixIconConstraints ?? compactConstraints,
            suffixIcon: suffixIcon,
            suffixIconConstraints:
                suffixIconConstraints ?? compactConstraints,
            fillColor: fillColor ?? t.inputDecorationTheme.fillColor,
            isDense: context.isShortViewport ? true : null,
            contentPadding: contentPadding ??
                (context.isShortViewport
                    ? const EdgeInsets.symmetric(horizontal: 16, vertical: 9.5)
                    : null),
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
