import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/supplier_parts.dart'
    show inventorySheetKeyboardLift;
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

// The Add Product form's parts (#487, `phone-add-product-light.png` /
// `wide-add-product-light.png`). Plain data in, theme-only styling, 48dp
// targets. The screen owns every value and write; these only draw.

/// The theme's input fill (the `AppInput` box colour).
Color _inputFill(ThemeData t) =>
    t.inputDecorationTheme.fillColor ?? t.colorScheme.surface;

/// The theme's input radius (the `AppInput` box shape).
BorderRadius _inputRadius(ThemeData t) {
  final border = t.inputDecorationTheme.border;
  return border is OutlineInputBorder
      ? border.borderRadius
      : BorderRadius.circular(AppSpacing.borderRadiusM);
}

Color _muted(ThemeData t) =>
    t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

/// One card of the form: a 40 `IconTile` (fixed info tone), the title, an
/// optional muted subtitle and an optional [trailing] control (the Track Empty
/// Crates switch), then [children].
class ProductFormSection extends StatelessWidget {
  const ProductFormSection({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.children = const [],
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InventoryFormCard(
      children: [
        Row(
          children: [
            IconTile(icon: icon, size: 40),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: context
                        .extraBoldStyle(16)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: context
                          .regularStyle(13)
                          .copyWith(color: _muted(t)),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              SizedBox(width: context.getRSize(8)),
              trailing!,
            ],
          ],
        ),
        if (children.isNotEmpty) ...[
          SizedBox(height: context.getRSize(16)),
          ...children,
        ],
      ],
    );
  }
}

/// The label over a box that is not an `AppInput` (a picker, the stepper, the
/// unit chips): Bold 12, muted — the `AppInput` label's look.
class ProductFieldLabel extends StatelessWidget {
  const ProductFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(8)),
      child: Text(
        text,
        style: context.boldStyle(12).copyWith(color: _muted(Theme.of(context))),
      ),
    );
  }
}

/// The dashed "Add Photo" square beside Product Name. Shows [pendingBytes]
/// (a picked or catalogue photo) when set, with a 48dp remove ✕ in the corner.
/// The whole square taps to pick a photo.
class ProductPhotoBox extends StatelessWidget {
  const ProductPhotoBox({
    super.key,
    required this.onPick,
    this.pendingBytes,
    this.onRemove,
  });

  final Uint8List? pendingBytes;
  final VoidCallback onPick;
  final VoidCallback? onRemove;

  /// The square's edge: the mockup's 92, never under a 48dp target.
  static double edge(BuildContext context) =>
      context.getRSize(92).clamp(kMinInteractiveDimension, double.infinity);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final side = edge(context);
    final radius = _inputRadius(t);
    final bytes = pendingBytes;
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              button: true,
              label: bytes == null ? 'Add photo' : 'Change photo',
              child: Material(
                color: _inputFill(t),
                borderRadius: radius,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onPick,
                  child: bytes != null
                      ? Image.memory(bytes, fit: BoxFit.cover)
                      : CustomPaint(
                          painter: _DashedBorderPainter(
                            color: _muted(t),
                            radius: radius,
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppIcon(
                                  AppIcons.camera,
                                  size: context.getRSize(26),
                                  color: t.colorScheme.primary,
                                ),
                                SizedBox(height: context.getRSize(6)),
                                Text(
                                  'Add Photo',
                                  textAlign: TextAlign.center,
                                  style: context
                                      .semiBoldStyle(12)
                                      .copyWith(color: _muted(t)),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
          if (bytes != null && onRemove != null)
            PositionedDirectional(
              top: 0,
              end: 0,
              child: IconButton(
                tooltip: 'Remove photo',
                onPressed: onRemove,
                constraints: const BoxConstraints(
                  minWidth: kMinInteractiveDimension,
                  minHeight: kMinInteractiveDimension,
                ),
                icon: Container(
                  padding: EdgeInsets.all(context.getRSize(4)),
                  decoration: BoxDecoration(
                    color: t.colorScheme.surface,
                    shape: BoxShape.circle,
                  ),
                  child: AppIcon(
                    AppIcons.close,
                    size: context.getRSize(16),
                    color:
                        (t.extension<AppFixedColors>() ?? AppFixedColors.light)
                            .danger,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A dashed rounded outline (the empty photo square).
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = radius.toRRect(Offset.zero & size).deflate(0.6);
    final path = Path()..addRRect(rrect);
    const dash = 5.0;
    const gap = 4.0;
    for (final ui.PathMetric metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dash), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

/// A dropdown-style box (#487: Category, Brand / Manufacturer, Supplier): the
/// chosen [value] or a muted [placeholder], a 48dp clear ✕ when [onClear] is
/// set and a value is shown, and the chevron. The whole box is a 48dp+ target
/// that opens the picker sheet.
class ProductPickerField extends StatelessWidget {
  const ProductPickerField({
    super.key,
    required this.value,
    required this.placeholder,
    required this.onTap,
    this.onClear,
  });

  final String? value;
  final String placeholder;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final radius = _inputRadius(t);
    final has = value != null && value!.trim().isNotEmpty;
    return Semantics(
      button: true,
      child: Material(
        color: _inputFill(t),
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: context
                  .getRSize(52)
                  .clamp(kMinInteractiveDimension, double.infinity),
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: context.getRSize(16),
                end: context.getRSize(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      has ? value! : placeholder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: has
                          ? context
                                .mediumStyle(14)
                                .copyWith(color: t.colorScheme.onSurface)
                          : context.regularStyle(14).copyWith(color: _muted(t)),
                    ),
                  ),
                  if (has && onClear != null)
                    InventoryFieldClear(onPressed: onClear!),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.getRSize(4),
                    ),
                    child: AppIcon(
                      AppIcons.chevronDown,
                      size: context.getRSize(22),
                      color: _muted(t),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One choice in a [ProductPickerSheet].
class ProductPickerOption {
  const ProductPickerOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// What a [ProductPickerSheet] closed with.
sealed class ProductPickerChoice {
  const ProductPickerChoice();
}

/// An existing option, by id.
final class ProductPickerPicked extends ProductPickerChoice {
  const ProductPickerPicked(this.id);

  final String id;
}

/// A new name to add. The form creates it when the product is saved.
final class ProductPickerNew extends ProductPickerChoice {
  const ProductPickerNew(this.name);

  final String name;
}

/// The sheet's extra full-form action (Supplier: "Add new supplier").
final class ProductPickerAddFull extends ProductPickerChoice {
  const ProductPickerAddFull();
}

/// Opens a [ProductPickerSheet] on the theme's sheet.
Future<ProductPickerChoice?> showProductPickerSheet(
  BuildContext context, {
  required String title,
  required String searchHint,
  required List<ProductPickerOption> options,
  String? selectedId,
  List<String> starterNames = const [],
  String? addFullLabel,
}) {
  return showModalBottomSheet<ProductPickerChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ProductPickerSheet(
      title: title,
      searchHint: searchHint,
      options: options,
      selectedId: selectedId,
      starterNames: starterNames,
      addFullLabel: addFullLabel,
    ),
  );
}

/// A searchable list of [options] with "Add new…" (#487). Typing narrows the
/// list; "Add new “name”" closes with [ProductPickerNew]. While there are no
/// options at all, [starterNames] (the trade's starter categories) are offered
/// as new names. [addFullLabel] adds a full-form action at the top.
class ProductPickerSheet extends StatefulWidget {
  const ProductPickerSheet({
    super.key,
    required this.title,
    required this.searchHint,
    required this.options,
    this.selectedId,
    this.starterNames = const [],
    this.addFullLabel,
  });

  final String title;
  final String searchHint;
  final List<ProductPickerOption> options;
  final String? selectedId;
  final List<String> starterNames;
  final String? addFullLabel;

  @override
  State<ProductPickerSheet> createState() => _ProductPickerSheetState();
}

class _ProductPickerSheetState extends State<ProductPickerSheet> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchCtrl.text.trim();
    final lower = query.toLowerCase();
    final matches = widget.options
        .where((o) => o.label.toLowerCase().contains(lower))
        .toList();
    final exact = widget.options.any((o) => o.label.toLowerCase() == lower);
    final starters = widget.options.isEmpty && query.isEmpty
        ? widget.starterNames
        : const <String>[];
    final media = MediaQuery.of(context);
    final lift = inventorySheetKeyboardLift(context);
    final maxHeight = (media.size.height - lift - media.padding.top) * 0.9;
    final gutter = context.getRSize(20);

    return Padding(
      padding: EdgeInsets.only(bottom: lift),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            context.getRSize(12),
            gutter,
            context.getRSize(16) + context.deviceBottomPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InventorySheetHeader(title: widget.title),
              SizedBox(height: context.getRSize(16)),
              AppInput(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                hintText: widget.searchHint,
                prefixIcon: const InventorySearchIcon(),
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(top: context.getRSize(8)),
                  children: [
                    if (widget.addFullLabel != null)
                      InventorySuggestionTile(
                        label: widget.addFullLabel!,
                        icon: AppIcons.addCircle,
                        emphasis: true,
                        onTap: () => Navigator.pop(
                          context,
                          const ProductPickerAddFull(),
                        ),
                      ),
                    if (!exact)
                      InventorySuggestionTile(
                        label: query.isEmpty ? 'Add new…' : 'Add new “$query”',
                        icon: AppIcons.addCircle,
                        emphasis: true,
                        onTap: query.isEmpty
                            ? _searchFocus.requestFocus
                            : () => Navigator.pop(
                                context,
                                ProductPickerNew(query),
                              ),
                      ),
                    for (final o in matches)
                      InventorySuggestionTile(
                        label: o.label,
                        icon: o.id == widget.selectedId
                            ? AppIcons.check
                            : AppIcons.chevronRight,
                        onTap: () =>
                            Navigator.pop(context, ProductPickerPicked(o.id)),
                      ),
                    for (final name in starters)
                      InventorySuggestionTile(
                        label: name,
                        icon: AppIcons.addCircle,
                        onTap: () =>
                            Navigator.pop(context, ProductPickerNew(name)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One unit chip (#487): a 48dp stadium, filled primary with a check when
/// [selected], else the input fill with a hairline.
class ProductUnitChip extends StatelessWidget {
  const ProductUnitChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ink = selected ? t.colorScheme.onPrimary : t.colorScheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? t.colorScheme.primary : _inputFill(t),
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? t.colorScheme.primary : t.dividerColor,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
              minWidth: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    AppIcon(
                      AppIcons.check,
                      size: context.getRSize(16),
                      color: ink,
                    ),
                    SizedBox(width: context.getRSize(6)),
                  ],
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: context.semiBoldStyle(14).copyWith(color: ink),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Opening Quantity stepper: − (input fill), the [field] in the middle,
/// + (primary tint). Each button is a 48dp+ square.
class ProductQuantityStepper extends StatelessWidget {
  const ProductQuantityStepper({
    super.key,
    required this.field,
    required this.onDecrement,
    required this.onIncrement,
  });

  final Widget field;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tint = t.extension<AppSchemeColors>()?.primaryTint ?? _inputFill(t);
    final gap = SizedBox(width: context.getRSize(10));
    return Row(
      children: [
        _StepButton(
          tooltip: 'Less',
          icon: AppIcons.minus,
          fill: _inputFill(t),
          ink: t.colorScheme.onSurface,
          onPressed: onDecrement,
        ),
        gap,
        Expanded(child: field),
        gap,
        _StepButton(
          tooltip: 'More',
          icon: AppIcons.add,
          fill: tint,
          ink: t.colorScheme.primary,
          onPressed: onIncrement,
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.tooltip,
    required this.icon,
    required this.fill,
    required this.ink,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color fill;
  final Color ink;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final side = context
        .getRSize(52)
        .clamp(kMinInteractiveDimension, double.infinity);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: fill,
        borderRadius: _inputRadius(t),
        child: InkWell(
          borderRadius: _inputRadius(t),
          onTap: onPressed,
          child: SizedBox(
            width: side,
            height: side,
            child: Center(
              child: AppIcon(icon, size: context.getRSize(22), color: ink),
            ),
          ),
        ),
      ),
    );
  }
}

/// One profit row's words and figure, already formatted.
class ProductProfitLine {
  const ProductProfitLine({
    required this.title,
    required this.share,
    required this.amount,
    required this.isLoss,
  });

  /// "Retail profit", "Wholesale profit per crate".
  final String title;

  /// "10% of selling price".
  final String share;

  /// The formatted amount ("₦1,500").
  final String amount;
  final bool isLoss;
}

/// The profit rows (#487): a tinted box, one row per [lines] entry — a 40
/// `IconTile` (green trend, or danger when it is a loss), the title and share,
/// and the amount (fixed danger for a loss) — hairlines between rows.
class ProductProfitBox extends StatelessWidget {
  const ProductProfitBox({super.key, required this.lines});

  final List<ProductProfitLine> lines;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: _inputFill(t),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Column(
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) Divider(height: 1, color: t.dividerColor),
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.getRSize(10)),
              child: Row(
                children: [
                  IconTile(
                    icon: lines[i].isLoss
                        ? AppIcons.trendingDown
                        : AppIcons.profit,
                    tone: lines[i].isLoss
                        ? IconTileTone.danger
                        : IconTileTone.green,
                    size: 40,
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          lines[i].title,
                          style: context
                              .semiBoldStyle(14)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        Text(
                          lines[i].share,
                          style: context
                              .regularStyle(12)
                              .copyWith(color: _muted(t)),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Text(
                    lines[i].amount,
                    style: context
                        .extraBoldStyle(17)
                        .copyWith(
                          color: lines[i].isLoss
                              ? f.danger
                              : t.colorScheme.onSurface,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The wide layout's preview of the product tile (#487): the photo, else the
/// category's tint and icon; the name with a stock `TagPill`; the detail line;
/// the retail price large in primary.
class ProductPreviewCard extends StatelessWidget {
  const ProductPreviewCard({
    super.key,
    required this.name,
    required this.stockLabel,
    required this.detailLine,
    required this.priceLabel,
    this.categoryName,
    this.photoBytes,
  });

  final String name;
  final String stockLabel;
  final String detailLine;
  final String priceLabel;
  final String? categoryName;
  final Uint8List? photoBytes;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final visual = categoryVisual(categoryName, f);
    final bytes = photoBytes;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: AppDecorations.card(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: context.getRSize(110),
            color: visual.tint,
            alignment: Alignment.center,
            child: bytes != null
                ? Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                  )
                : AppIcon(
                    visual.icon,
                    size: context.getRSize(48),
                    color: visual.iconColor,
                  ),
          ),
          Padding(
            padding: EdgeInsets.all(context.getRSize(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context
                            .boldStyle(16)
                            .copyWith(color: t.colorScheme.onSurface),
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    TagPill(label: stockLabel),
                  ],
                ),
                if (detailLine.isNotEmpty) ...[
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    detailLine,
                    style: context.regularStyle(13).copyWith(color: _muted(t)),
                  ),
                ],
                SizedBox(height: context.getRSize(8)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    priceLabel,
                    style: context
                        .extraBoldStyle(28)
                        .copyWith(color: t.colorScheme.primary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The wide layout's fixed side panel (#487): Surface with a hairline on its
/// leading edge; "Preview" and its subtitle, the [preview] card and the
/// optional [profit] rows scroll in the space above [actions], which stay
/// pinned at the bottom in their own band.
class ProductPreviewPanel extends StatelessWidget {
  const ProductPreviewPanel({
    super.key,
    required this.preview,
    required this.actions,
    this.profit,
  });

  /// The panel's fixed width (the mockup's ~380).
  static const double width = 380;

  final Widget preview;
  final Widget? profit;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pad = context.getRSize(24);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: BorderDirectional(start: BorderSide(color: t.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, context.getRSize(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Preview',
                    style: context
                        .extraBoldStyle(18)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    'How this product will look on the sales screen.',
                    style: context.regularStyle(13).copyWith(color: _muted(t)),
                  ),
                  SizedBox(height: context.getRSize(16)),
                  preview,
                  if (profit != null) ...[
                    SizedBox(height: context.getRSize(16)),
                    profit!,
                  ],
                ],
              ),
            ),
          ),
          // The buttons sit in their own band under a hairline: the preview
          // scrolls in the space above it and never runs underneath.
          Container(
            decoration: BoxDecoration(
              color: t.colorScheme.surface,
              border: Border(top: BorderSide(color: t.dividerColor)),
            ),
            padding: EdgeInsets.fromLTRB(
              pad,
              context.getRSize(16),
              pad,
              context.getRSize(16) + context.deviceBottomPadding,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: actions,
            ),
          ),
        ],
      ),
    );
  }
}
