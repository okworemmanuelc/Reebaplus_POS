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

  const SharedScaffold({
    super.key,
    this.appBar,
    this.body,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.backgroundColor,
    required this.activeRoute,
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
      appBar:
          appBar ?? AppBar(leading: (isPrimaryRoute && !context.isDesktop) ? const MenuButton() : null),
      backgroundColor: backgroundColor,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      bottomNavigationBar: bottomNavigationBar,
      drawer: context.isDesktop ? null : AppDrawer(activeRoute: activeRoute),
      body: body,
    );
  }
}
