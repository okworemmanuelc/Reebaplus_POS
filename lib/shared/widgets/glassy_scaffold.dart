import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';

/// A reusable Scaffold wrapper that implements the "Glassy & Modernistic UI Standard" (§10.1+).
/// Features a gradient background and a scroll-reactive AppBar that dims when the user scrolls.
class GlassyScaffold extends StatefulWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final bool centerTitle;

  const GlassyScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.bottom,
    this.centerTitle = true,
  });

  @override
  State<GlassyScaffold> createState() => _GlassyScaffoldState();
}

class _GlassyScaffoldState extends State<GlassyScaffold> {
  double _scrollOffset = 0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isScrolled = _scrollOffset > 10;

    return Container(
      decoration: AppDecorations.glassyBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            widget.title,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: widget.centerTitle,
          actions: widget.actions,
          backgroundColor: isScrolled
              ? t.colorScheme.surface.withValues(alpha: 0.8)
              : Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          bottom: widget.bottom,
        ),
        body: NotificationListener<ScrollUpdateNotification>(
          onNotification: (notif) {
            if (notif.metrics.axis == Axis.vertical) {
              if ((_scrollOffset > 10) != (notif.metrics.pixels > 10)) {
                setState(() => _scrollOffset = notif.metrics.pixels);
              } else {
                _scrollOffset = notif.metrics.pixels;
              }
            }
            return false;
          },
          child: widget.body,
        ),
      ),
    );
  }
}
