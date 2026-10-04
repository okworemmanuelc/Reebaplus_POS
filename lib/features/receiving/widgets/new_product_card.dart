import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class NewProductCard extends StatelessWidget {
  final Color cardCol;
  final Color textCol;
  final VoidCallback? onTap;

  const NewProductCard({
    super.key,
    required this.cardCol,
    required this.textCol,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: cardCol,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: context.getRSize(48),
                height: context.getRSize(48),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  AppIcons.add,
                  color: Theme.of(context).colorScheme.primary,
                  size: context.getRSize(24),
                ),
              ),
              SizedBox(height: context.getRSize(16)),
              Text(
                'New Product',
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
