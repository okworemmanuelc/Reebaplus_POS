import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';

class SharedScaffold extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomNavigationBar;
  final Color? backgroundColor;
  final String activeRoute;

  /// When true the [Scaffold] gets no app bar at all, because [body] owns one
  /// itself as a sliver inside its own scroll view.
  ///
  /// ### Why this exists (issue #259 / PRD #239)
  ///
  /// A `Scaffold.appBar` is fixed chrome: it is laid out first and the body
  /// gets whatever is left. On POS at 800x360 that is part of what starved the
  /// product grid to 0.0dp. For the top bar to scroll away it has to *be* a
  /// sliver in the body's scroll view, which means the Scaffold must not also
  /// render one — and passing `appBar: null` is not enough, because that
  /// substitutes the default bar below.
  ///
  /// The drawer is unaffected: it stays on this [Scaffold], and [DrawerHost]
  /// keeps the body underneath it, so a `MenuButton` inside the body's sliver
  /// app bar still opens it.
  final bool bodyOwnsAppBar;

  const SharedScaffold({
    super.key,
    this.appBar,
    this.body,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.backgroundColor,
    required this.activeRoute,
    this.bodyOwnsAppBar = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool isPrimaryRoute = [
      'pos',
      'inventory',
      'orders',
      'cart',
    ].contains(activeRoute);

    return Scaffold(
      appBar: bodyOwnsAppBar
          ? null
          : appBar ?? AppBar(leading: (isPrimaryRoute && !context.isDesktop) ? const MenuButton() : null),
      backgroundColor: backgroundColor,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      bottomNavigationBar: bottomNavigationBar,
      drawer: context.isDesktop ? null : AppDrawer(activeRoute: activeRoute),
      // DrawerHost must sit *inside* this Scaffold so it can reach it — see its
      // doc comment. Left null when there is no body: a screen with nothing in
      // it has no menu button to open the drawer from either.
      body: body == null ? null : DrawerHost(child: body!),
    );
  }
}
