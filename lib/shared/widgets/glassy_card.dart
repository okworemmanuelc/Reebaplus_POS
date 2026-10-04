import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// Legacy card widget retained under this name for compatibility.
/// Keeps its old name for now and will be renamed in Wave 2.
class GlassyCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Border? border;
  final Color? backgroundColor;

  const GlassyCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = 16.0,
    this.border,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final baseDec = AppDecorations.card(context, radius: radius);
    return Container(
      margin: margin,
      padding: padding ?? EdgeInsets.all(context.getRSize(16)),
      // Clip to the rounded corners, as the old ClipRRect did, so edge-to-edge
      // children (coloured strips, images, ripples) don't poke out square.
      clipBehavior: Clip.antiAlias,
      decoration: baseDec.copyWith(
        color: backgroundColor ?? baseDec.color,
        border: border ?? baseDec.border,
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
