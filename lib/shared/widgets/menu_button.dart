import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

class MenuButton extends StatelessWidget {
  const MenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;

    return SpotlightTarget(
      id: SpotlightTargetId.menuButton,
      child: Builder(
        builder: (ctx) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Scaffold.of(ctx).openDrawer(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 2.5,
                width: context.getRSize(22),
                decoration: BoxDecoration(
                  color: text,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                height: 2.5,
                width: context.getRSize(16),
                decoration: BoxDecoration(
                  color: primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                height: 2.5,
                width: context.getRSize(22),
                decoration: BoxDecoration(
                  color: text,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
}
