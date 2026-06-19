import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class AppDropdown<T> extends FormField<T> {
  final T? currentValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String? labelText;
  final String? hintText;
  final Widget? prefixIcon;
  final bool isExpanded;
  final double? width;
  final EdgeInsetsGeometry? contentPadding;

  AppDropdown({
    super.key,
    required T? value,
    required this.items,
    required this.onChanged,
    this.labelText,
    this.hintText,
    this.prefixIcon,
    this.isExpanded = true,
    this.width,
    this.contentPadding,
    super.validator,
  }) : currentValue = value,
       super(
          initialValue: value,
          builder: (FormFieldState<T> field) {
            final _AppDropdownState<T> state = field as _AppDropdownState<T>;
            return state.buildUI(state.context);
          },
        );

  @override
  FormFieldState<T> createState() => _AppDropdownState<T>();
}

class _AppDropdownState<T> extends FormFieldState<T> {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _key = GlobalKey();
  OverlayEntry? _overlayEntry;
  bool _isOpen = false;

  @override
  AppDropdown<T> get widget => super.widget as AppDropdown<T>;

  @override
  void didUpdateWidget(AppDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentValue != oldWidget.currentValue && widget.currentValue != value) {
      didChange(widget.currentValue);
    }
  }

  @override
  void dispose() {
    _closeDropdown();
    super.dispose();
  }

  void _toggleDropdown() {
    if (_isOpen) {
      _closeDropdown();
    } else {
      _openDropdown();
    }
  }

  void _closeDropdown() {
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
      setState(() => _isOpen = false);
    }
  }

  void _openDropdown() {
    final RenderBox renderBox = _key.currentContext!.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    final screenHeight = MediaQuery.of(context).size.height;
    
    const maxMenuHeight = 250.0;
    final spaceBelow = screenHeight - offset.dy - size.height;
    final spaceAbove = offset.dy;
    
    bool openUpwards = false;
    if (spaceBelow < maxMenuHeight && spaceAbove > spaceBelow) {
      openUpwards = true;
    }

    _overlayEntry = _createOverlayEntry(size, openUpwards);
    Overlay.of(context).insert(_overlayEntry!);
    setState(() => _isOpen = true);
  }

  OverlayEntry _createOverlayEntry(Size size, bool openUpwards) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final dropdownColor = isDark
        ? theme.colorScheme.surface.withValues(alpha: 0.7)
        : theme.colorScheme.surface.withValues(alpha: 0.85);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : theme.colorScheme.primary.withValues(alpha: 0.1);
        
    return OverlayEntry(
      builder: (context) => Stack(
        children: [
          GestureDetector(
            onTap: _closeDropdown,
            behavior: HitTestBehavior.translucent,
            child: Container(
              color: Colors.transparent,
              width: double.infinity,
              height: double.infinity,
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: Offset(0, openUpwards ? -8.0 : size.height + 8.0),
            targetAnchor: openUpwards ? Alignment.topLeft : Alignment.bottomLeft,
            followerAnchor: openUpwards ? Alignment.bottomLeft : Alignment.topLeft,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                width: size.width,
                constraints: const BoxConstraints(maxHeight: 250),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 16,
                      offset: Offset(0, openUpwards ? -8 : 8),
                    )
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: dropdownColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: borderColor, width: 1.5),
                      ),
                      child: ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shrinkWrap: true,
                        children: widget.items.map((item) {
                          final isSelected = item.value == value;
                          return InkWell(
                            onTap: () {
                              didChange(item.value);
                              widget.onChanged(item.value);
                              _closeDropdown();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected 
                                    ? theme.colorScheme.primary.withValues(alpha: 0.1)
                                    : Colors.transparent,
                              ),
                              child: DefaultTextStyle(
                                style: TextStyle(
                                  color: isSelected 
                                      ? theme.colorScheme.primary 
                                      : theme.colorScheme.onSurface,
                                  fontSize: 14,
                                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                                ),
                                child: item.child,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
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

  Widget buildUI(BuildContext context) {
    final t = Theme.of(context);
    final subtextColor = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    
    // NOTE: a plain loop (not `items.firstWhere(... orElse: () => items.first)`)
    // on purpose. When this dropdown is instantiated as `AppDropdown<String?>`
    // but fed `items` built with non-null String values (their runtime element
    // type is `DropdownMenuItem<String>`), `firstWhere`'s reified `orElse`
    // closure types as `() => DropdownMenuItem<String?>` and fails Dart's
    // runtime subtype check ("not a subtype of ... orElse"). The loop sidesteps
    // that mismatch regardless of how T is bound.
    Widget? selectedChild;
    if (value != null && widget.items.isNotEmpty) {
      for (final item in widget.items) {
        if (item.value == value) {
          selectedChild = item.child;
          break;
        }
      }
    }

    final isDark = t.brightness == Brightness.dark;
    final buttonColor = isDark
        ? t.colorScheme.surface.withValues(alpha: 0.25)
        : t.colorScheme.surface.withValues(alpha: 0.6);

    final content = GestureDetector(
      onTap: _toggleDropdown,
      child: CompositedTransformTarget(
        link: _layerLink,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              key: _key,
              padding: widget.contentPadding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: buttonColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: hasError 
                      ? Colors.red 
                      : (isDark ? Colors.white.withValues(alpha: 0.05) : t.colorScheme.primary.withValues(alpha: 0.05)),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  if (widget.prefixIcon != null) ...[
                    widget.prefixIcon!,
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: selectedChild != null
                        ? DefaultTextStyle(
                            style: TextStyle(
                              color: t.colorScheme.onSurface,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              overflow: TextOverflow.ellipsis,
                            ),
                            child: selectedChild,
                          )
                        : Text(
                            widget.hintText ?? '',
                            style: TextStyle(
                              color: subtextColor,
                              fontSize: 13,
                            ),
                          ),
                  ),
                  Icon(
                    _isOpen ? FontAwesomeIcons.chevronUp.data : FontAwesomeIcons.chevronDown.data,
                    size: 13,
                    color: subtextColor,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.labelText != null) ...[
          Text(
            widget.labelText!,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: subtextColor,
            ),
          ),
          const SizedBox(height: 8),
        ],
        content,
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 12),
            child: Text(
              errorText!,
              style: const TextStyle(
                color: Colors.red,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );

    if (widget.width != null) {
      return SizedBox(width: widget.width, child: column);
    }
    return column;
  }
}
