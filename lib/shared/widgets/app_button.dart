import 'dart:math';
import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

enum AppButtonVariant { primary, secondary, outline, danger, ghost, success }

enum AppButtonSize { xsmall, small, normal, large }

class AppButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;

  /// Async tap handler. The button locks on the FIRST tap (before the callback
  /// runs or anything is awaited), shows the loading spinner, and unlocks when
  /// the returned future finishes (or throws). The spinner hides while another
  /// route covers the button, and the lock holds. Use instead of [onPressed]
  /// for actions that save, print or navigate. Do not set both.
  final Future<void> Function()? onAsyncPressed;
  final AppButtonVariant variant;
  final bool isLoading;
  final bool isFullWidth;
  final IconData? icon;
  final IconData? trailingIcon;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final AppButtonSize size;

  const AppButton({
    super.key,
    required this.text,
    this.onPressed,
    this.onAsyncPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.normal,
    this.isLoading = false,
    this.isFullWidth = true,
    this.icon,
    this.trailingIcon,
    this.width,
    this.height,
    this.padding,
  }) : assert(
         onPressed == null || onAsyncPressed == null,
         'Set either onPressed or onAsyncPressed, not both.',
       );

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _running = false;

  Future<void> _handleAsyncTap() async {
    if (_running) return;
    // Set synchronously, before the callback or any await: this is the lock.
    _running = true;
    setState(() {});
    try {
      await widget.onAsyncPressed!();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final variant = widget.variant;
    final size = widget.size;
    final icon = widget.icon;
    final trailingIcon = widget.trailingIcon;
    // Still locked while a dialog or sheet covers this button, but no spinner:
    // the app is waiting on the person then, not on a save.
    final spinning = _running && (ModalRoute.isCurrentOf(context) ?? true);
    final isLoading = widget.isLoading || spinning;
    final VoidCallback? onTap = widget.onAsyncPressed != null
        ? _handleAsyncTap
        : widget.onPressed;
    final t = Theme.of(context);
    final bool isDisabled = onTap == null || isLoading;

    // Define colors based on variant
    Color? bgColor;
    Color textColor;
    BorderSide? border;
    List<Color>? gradient;

    switch (variant) {
      case AppButtonVariant.primary:
        final primary = t.colorScheme.primary;
        final secondary = t.colorScheme.secondary;
        // Use a gradient that blends primary and secondary (or a darkened primary as fallback)
        gradient = [
          secondary != primary ? secondary : primary.withValues(alpha: 0.8),
          primary,
        ];
        textColor = t.colorScheme.onPrimary != Colors.transparent
            ? t.colorScheme.onPrimary
            : Colors.white;
        break;
      case AppButtonVariant.secondary:
        bgColor = t.colorScheme.primary.withValues(alpha: 0.12);
        textColor = t.colorScheme.primary;
        break;
      case AppButtonVariant.outline:
        bgColor = Colors.transparent;
        textColor = t.colorScheme.primary;
        border = BorderSide(color: t.colorScheme.primary, width: 1.5);
        break;
      case AppButtonVariant.danger:
        bgColor = t.colorScheme.error.withValues(alpha: 0.1);
        textColor = t.colorScheme.error;
        break;
      case AppButtonVariant.ghost:
        bgColor = Colors.transparent;
        textColor = t.textTheme.bodyMedium?.color ?? t.colorScheme.onSurface;
        break;
      case AppButtonVariant.success:
        // Match the success banner green (AppNotification) so a "success"
        // button reads as the same green everywhere, on every theme.
        final successColor = Colors.green.shade600;
        gradient = [Color.lerp(successColor, Colors.white, 0.1)!, successColor];
        textColor = Colors.white;
        break;
    }

    if (isDisabled &&
        (variant == AppButtonVariant.primary ||
            variant == AppButtonVariant.success)) {
      gradient = [Colors.grey.shade400, Colors.grey.shade500];
    } else if (isDisabled) {
      bgColor = Colors.grey.withValues(alpha: 0.1);
      textColor = Colors.grey;
    }

    Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isLoading) ...[
          SizedBox(
            width: context.getRSize(16),
            height: context.getRSize(16),
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(textColor),
            ),
          ),
          SizedBox(width: context.getRSize(12)),
        ] else if (icon != null) ...[
          Icon(icon, size: context.getRSize(18), color: textColor),
          SizedBox(width: context.getRSize(10)),
        ],
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              color: textColor,
              fontSize: context.getRFontSize(
                size == AppButtonSize.xsmall
                    ? 11
                    : (size == AppButtonSize.small
                          ? 13
                          : (size == AppButtonSize.large ? 17 : 15)),
              ),
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
        ),
        if (!isLoading && trailingIcon != null) ...[
          SizedBox(width: context.getRSize(10)),
          Icon(trailingIcon, size: context.getRSize(18), color: textColor),
        ],
      ],
    );

    return Opacity(
      opacity: isDisabled ? 0.7 : 1.0,
      child: Container(
        width: widget.isFullWidth
            ? (widget.width ?? double.infinity)
            : widget.width,
        height:
            widget.height ??
            (size == AppButtonSize.xsmall
                ? 32.0
                : (size == AppButtonSize.small
                      ? 40.0
                      : max(
                          kMinInteractiveDimension,
                          context.getRSize(
                            size == AppButtonSize.large ? 60 : 54,
                          ),
                        ))),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: gradient != null
              ? LinearGradient(
                  colors: gradient,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: gradient == null ? bgColor : null,
          border: border != null ? Border.fromBorderSide(border) : null,
          boxShadow:
              (variant == AppButtonVariant.primary ||
                      variant == AppButtonVariant.success) &&
                  !isDisabled
              ? [
                  BoxShadow(
                    color:
                        (variant == AppButtonVariant.success
                                ? Colors.green.shade600
                                : t.colorScheme.primary)
                            .withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isDisabled ? null : onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding:
                  widget.padding ??
                  EdgeInsets.symmetric(horizontal: context.getRSize(16)),
              child: Center(child: content),
            ),
          ),
        ),
      ),
    );
  }
}
