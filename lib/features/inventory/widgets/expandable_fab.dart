import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class ExpandableFab extends StatefulWidget {
  final VoidCallback onAddNewProduct;
  final VoidCallback onReceiveStock;
  final bool reserveBottomInset;

  const ExpandableFab({
    super.key,
    required this.onAddNewProduct,
    required this.onReceiveStock,
    this.reserveBottomInset = true,
  });

  @override
  State<ExpandableFab> createState() => _ExpandableFabState();
}

class _ExpandableFabState extends State<ExpandableFab> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _expandAnimation;
  bool _isOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      value: _isOpen ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      curve: Curves.fastOutSlowIn,
      reverseCurve: Curves.easeOutQuad,
      parent: _controller,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _isOpen = !_isOpen;
      if (_isOpen) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final double defaultWidth = rSize(context, 165);

    Widget result = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _buildAction(
          context,
          'Receive Stock',
          FontAwesomeIcons.truckArrowRight.data,
          widget.onReceiveStock,
          0,
        ),
        _buildAction(
          context,
          'Add New Product',
          FontAwesomeIcons.plus.data,
          widget.onAddNewProduct,
          1,
        ),
        SizedBox(height: rSize(context, 16)),
        Container(
          height: rSize(context, 50),
          constraints: BoxConstraints(minWidth: defaultWidth),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [colorScheme.primary, colorScheme.secondary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggle,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: rSize(context, 16)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _controller,
                      builder: (context, child) {
                        return Transform.rotate(
                          angle: _controller.value * 0.785398, // pi/4
                          child: Icon(
                            FontAwesomeIcons.plus.data,
                            color: colorScheme.onPrimary,
                            size: rSize(context, 18),
                          ),
                        );
                      },
                    ),
                    SizedBox(width: rSize(context, 10)),
                    Text(
                      'Actions',
                      style: TextStyle(
                        color: colorScheme.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: rFontSize(context, 15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );

    if (widget.reserveBottomInset) {
      result = Padding(
        padding: EdgeInsets.only(bottom: context.deviceBottomPadding),
        child: result,
      );
    }
    return result;
  }

  Widget _buildAction(BuildContext context, String label, IconData icon, VoidCallback onPressed, int index) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double opacity = _expandAnimation.value;
        final double translation = (1 - _expandAnimation.value) * 20;
        
        if (opacity == 0) return const SizedBox.shrink();
        
        return Transform.translate(
          offset: Offset(0, translation),
          child: Opacity(
            opacity: opacity,
            child: Padding(
              padding: EdgeInsets.only(bottom: rSize(context, 12)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: rFontSize(context, 13),
                      ),
                    ),
                  ),
                  SizedBox(width: rSize(context, 12)),
                  SizedBox(
                    width: rSize(context, 48),
                    height: rSize(context, 48),
                    child: FloatingActionButton(
                      heroTag: 'fab_action_$index',
                      onPressed: () {
                        _toggle();
                        onPressed();
                      },
                      backgroundColor: Theme.of(context).cardColor,
                      elevation: 4,
                      child: Icon(icon, size: rSize(context, 18), color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
