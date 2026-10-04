import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// Legacy scaffold wrapper retained under this name for compatibility.
/// Features a flat page background and a solid AppBar with a hairline border and soft shadow.
class GlassyScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final bool centerTitle;

  const GlassyScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.body,
    this.actions,
    this.bottom,
    this.centerTitle = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: subtitle == null
              ? Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                )
              : Column(
                  crossAxisAlignment: centerTitle
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: context.getRFontSize(11),
                        color: t.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
          centerTitle: centerTitle,
          actions: actions,
          backgroundColor: t.colorScheme.surface,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          bottom: bottom,
          flexibleSpace: Container(
            decoration: BoxDecoration(
              color: t.colorScheme.surface,
              border: Border(
                bottom: BorderSide(color: t.dividerColor, width: 1),
              ),
              boxShadow: [
                BoxShadow(
                  color: topBarShadow,
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
        body: body,
      ),
    );
  }
}
