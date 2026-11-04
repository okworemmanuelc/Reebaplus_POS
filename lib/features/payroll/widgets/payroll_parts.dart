import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// The body width at which Payroll switches to its side-by-side tablet layout.
const double kPayrollSplitMinWidth = 900;

/// The widest a single-column Payroll page gets (a tablet held upright).
const double kPayrollColumnMaxWidth = 720;

/// The tablet's staff list (raw, not scaled).
const double kPayrollSidePaneWidth = 400;

/// The tablet History's staff and type filters (raw, not scaled).
const double kPayrollFilterPaneWidth = 250;

/// The chosen worker's pane width that fits three cards across.
const double kPayrollThreeCardsMinWidth = 800;

/// The top bar's height (CEO Settings' rule, #369).
double payrollTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// A muted text colour for the current theme.
Color payrollMuted(BuildContext context) {
  final t = Theme.of(context);
  return t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
}

/// The solid top bar of the Payroll screens: Surface, a hairline and the soft
/// `topBarShadow`, never changing on scroll.
class PayrollTopBar extends StatelessWidget implements PreferredSizeWidget {
  const PayrollTopBar({super.key, required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final shadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: preferredSize.height,
      titleSpacing: context.getRSize(8),
      centerTitle: false,
      backgroundColor: t.colorScheme.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          color: t.colorScheme.surface,
          border: Border(bottom: BorderSide(color: t.dividerColor, width: 1)),
          boxShadow: [
            BoxShadow(color: shadow, blurRadius: 4, offset: const Offset(0, 1)),
          ],
        ),
      ),
      title: child,
    );
  }
}

/// The live notification bell.
class PayrollLiveBell extends ConsumerWidget {
  const PayrollLiveBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.read(notificationProvider);
    return ValueListenableBuilder(
      valueListenable: service,
      builder: (context, _, _) => HeaderBell(
        count: service.unreadCount,
        onPressed: () => NotificationsModal.show(context),
      ),
    );
  }
}

/// The inner screens' header: a close or back button, the title, a primary
/// subtitle, then an optional trailing action.
class PayrollFormHeader extends StatelessWidget {
  const PayrollFormHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      children: [
        IconButton(
          tooltip: icon == AppIcons.close ? 'Close' : 'Back',
          onPressed: () => Navigator.maybePop(context),
          icon: Icon(
            icon,
            size: context.getRSize(26),
            color: t.colorScheme.onSurface,
          ),
        ),
        SizedBox(width: context.getRSize(4)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.screenTitleStyle.copyWith(
                  color: t.colorScheme.onSurface,
                ),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context
                    .semiBoldStyle(13)
                    .copyWith(color: t.colorScheme.primary),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// A pill chip. Selected = solid primary with white text; idle = an outlined
/// surface pill. The visible pill is compact; the tap area is at least 48dp.
class PayrollPillChip extends StatelessWidget {
  const PayrollPillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ink = selected ? t.colorScheme.onPrimary : t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
            minWidth: kMinInteractiveDimension,
          ),
          child: Center(
            widthFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? t.colorScheme.primary : t.colorScheme.surface,
                borderRadius: radius,
                border: Border.all(
                  color: selected ? t.colorScheme.primary : t.dividerColor,
                ),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(14),
                  vertical: context.getRSize(8),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: context.semiBoldStyle(14).copyWith(color: ink),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Overview / History switch, and the type switch on Add Pay Record: a
/// Surface 2 track with the chosen item raised on a white tile — or, with
/// [solid], filled primary.
class PayrollSegmented<T> extends StatelessWidget {
  const PayrollSegmented({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.solid = false,
    this.keyOf,
  });

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final bool solid;

  /// A key for each item (tests).
  final Key Function(T item)? keyOf;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final track = t.inputDecorationTheme.fillColor ?? t.dividerColor;
    final shadow = t.extension<AppSchemeColors>()?.cardShadow;
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
                                ? payrollMuted(context)
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

/// A worker's initials in a circle. [strong] is the raised gradient circle
/// (their own page, the row chosen on a tablet).
class PayrollAvatar extends StatelessWidget {
  const PayrollAvatar({
    super.key,
    required this.name,
    this.size = 48,
    this.strong = false,
  });

  final String name;
  final double size;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final side = context.getRSize(size);
    return Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: strong
          ? AppDecorations.primaryButtonGradient(
              context,
              shape: BoxShape.circle,
              glow: false,
            )
          : BoxDecoration(
              shape: BoxShape.circle,
              color: t.inputDecorationTheme.fillColor ?? t.dividerColor,
            ),
      child: Text(
        payrollInitials(name),
        style: context
            .boldStyle(size * 0.34)
            .copyWith(
              color: strong ? t.colorScheme.onPrimary : t.colorScheme.primary,
            ),
      ),
    );
  }
}

/// A coloured dot and label on a pale pill: Unpaid (red) or Paid (green).
class PayrollStatusPill extends StatelessWidget {
  const PayrollStatusPill({super.key, required this.paid, this.bare = false});

  final bool paid;

  /// Without the pill behind it (tablet lists).
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final dot = context.getRSize(9);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: dot,
          height: dot,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: paid ? f.greenDot : f.danger,
          ),
        ),
        SizedBox(width: context.getRSize(6)),
        Text(
          paid ? 'Paid' : 'Unpaid',
          style: context.boldStyle(13).copyWith(color: t.colorScheme.onSurface),
        ),
      ],
    );
    if (bare) return row;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: t.inputDecorationTheme.fillColor ?? t.dividerColor,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
      ),
      child: row,
    );
  }
}

/// A flat card with the standard inner padding.
class PayrollCard extends StatelessWidget {
  const PayrollCard({
    super.key,
    required this.child,
    this.padding = 16,
    this.selected = false,
    this.onTap,
  });

  final Widget child;
  final double padding;

  /// Outlined in primary (the row chosen on a tablet).
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    final base = AppDecorations.card(context, radius: AppSpacing.borderRadiusL);
    final body = Padding(
      padding: EdgeInsets.all(context.getRSize(padding)),
      child: child,
    );
    return DecoratedBox(
      decoration: selected
          ? base.copyWith(
              border: Border.all(color: t.colorScheme.primary, width: 2),
            )
          : base,
      child: onTap == null
          ? body
          : Material(
              type: MaterialType.transparency,
              child: InkWell(borderRadius: radius, onTap: onTap, child: body),
            ),
    );
  }
}

/// A label on the left, a figure on the right. [strong] for a total.
class PayrollLine extends StatelessWidget {
  const PayrollLine({
    super.key,
    required this.label,
    required this.value,
    this.onTap,
  });

  final String label;
  final String value;

  /// Makes the line tappable (shows a small pencil).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(5)),
      child: Row(
        children: [
          Expanded(child: Text(label, style: context.regularStyle(15))),
          if (onTap != null) ...[
            Icon(
              AppIcons.edit,
              size: context.getRSize(16),
              color: t.colorScheme.primary,
            ),
            SizedBox(width: context.getRSize(8)),
          ],
          Text(value, style: context.boldStyle(15)),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// The dashed rule above a total. Painted, so it works inside an
/// [IntrinsicHeight] row (the tablet's three cards).
class PayrollDashedRule extends StatelessWidget {
  const PayrollDashedRule({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 1,
    width: double.infinity,
    child: CustomPaint(painter: _DashPainter(Theme.of(context).dividerColor)),
  );
}

class _DashPainter extends CustomPainter {
  const _DashPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const dash = 5.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += dash * 2) {
      canvas.drawLine(Offset(x, 0.5), Offset(x + dash, 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}

/// A primary progress bar on a pale track.
class PayrollProgressBar extends StatelessWidget {
  const PayrollProgressBar({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
      child: LinearProgressIndicator(
        value: value.clamp(0, 1),
        backgroundColor: t.inputDecorationTheme.fillColor ?? t.dividerColor,
        valueColor: AlwaysStoppedAnimation<Color>(t.colorScheme.primary),
        minHeight: context.getRSize(8),
      ),
    );
  }
}

/// A form label above a field.
class PayrollFieldLabel extends StatelessWidget {
  const PayrollFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: context.getRSize(8)),
    child: Text(
      text,
      style: context.boldStyle(14).copyWith(color: payrollMuted(context)),
    ),
  );
}

/// A tile that opens a picker, shaped like an input: the value on the left,
/// [icon] on the right.
class PayrollPickerField extends StatelessWidget {
  const PayrollPickerField({
    super.key,
    required this.value,
    required this.onTap,
    this.icon = AppIcons.calendar,
  });

  final String value;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    return Material(
      color: t.inputDecorationTheme.fillColor ?? t.dividerColor,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(16),
            vertical: context.getRSize(15),
          ),
          child: Row(
            children: [
              Expanded(child: Text(value, style: context.mediumStyle(16))),
              Icon(
                icon,
                size: context.getRSize(22),
                color: payrollMuted(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Cash / Transfer / Other chips.
class PayrollMethodChips extends StatelessWidget {
  const PayrollMethodChips({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: context.getRSize(8),
    children: [
      for (final (id, label) in const [
        ('cash', 'Cash'),
        ('transfer', 'Transfer'),
        ('other', 'Other'),
      ])
        PayrollPillChip(
          key: ValueKey('payroll-method-$id'),
          label: label,
          selected: value == id,
          onTap: () => onChanged(id),
        ),
    ],
  );
}

/// The small icon square on a History line.
class PayrollKindIcon extends StatelessWidget {
  const PayrollKindIcon({super.key, required this.kind});

  final PayrollKind kind;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final side = context.getRSize(44);
    return Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.inputDecorationTheme.fillColor ?? t.dividerColor,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Icon(
        switch (kind) {
          PayrollKind.allowance => AppIcons.calendar,
          PayrollKind.bonus => AppIcons.bonus,
          _ => AppIcons.payrollWallet,
        },
        size: context.getRSize(22),
        color: t.colorScheme.primary,
      ),
    );
  }
}
