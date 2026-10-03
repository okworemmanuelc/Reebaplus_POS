import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The note under an Add Product field that the shared barcode catalogue
/// filled in (ADR 0029 §8, #332). The owning screen stops showing it once the
/// person edits that field.
class CatalogueFilledNote extends StatelessWidget {
  const CatalogueFilledNote({super.key});

  static const text =
      'Filled in from the Reebaplus product list. Check it before saving.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(
        top: context.getRSize(6),
        left: context.getRSize(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: context.getRSize(14), color: color),
          SizedBox(width: context.getRSize(6)),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
