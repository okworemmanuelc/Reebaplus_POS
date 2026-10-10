import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Keys for tests.
abstract final class StockRequestQuantitySheetKeys {
  static const field = Key('request-quantity-field');
  static const save = Key('request-quantity-save');
}

/// Request Stock's tap-and-hold sheet (#380): type how many of one product to
/// request. Returns the quantity (≥ 1), or null when dismissed.
///
/// Opened on the screen's own navigator, so inside the app frame it already
/// sits above the keyboard (the frame resizes for it); the bottom padding is
/// the navigation inset only (`deviceBottomPadding`), as every sheet.
class StockRequestQuantitySheet extends StatefulWidget {
  const StockRequestQuantitySheet({
    super.key,
    required this.productName,
    required this.sourceStoreName,
    required this.available,
    required this.initialQuantity,
  });

  final String productName;
  final String sourceStoreName;

  /// What the source store has, shown for reference (a request may ask for
  /// more; the holder can lower it when dispatching).
  final int available;

  /// Pre-filled: the quantity already on the request, else 1.
  final int initialQuantity;

  static Future<int?> show(
    BuildContext context, {
    required String productName,
    required String sourceStoreName,
    required int available,
    required int initialQuantity,
  }) {
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StockRequestQuantitySheet(
        productName: productName,
        sourceStoreName: sourceStoreName,
        available: available,
        initialQuantity: initialQuantity,
      ),
    );
  }

  @override
  State<StockRequestQuantitySheet> createState() =>
      _StockRequestQuantitySheetState();
}

class _StockRequestQuantitySheetState extends State<StockRequestQuantitySheet> {
  late final TextEditingController _ctrl = TextEditingController(
    text: '${widget.initialQuantity}',
  );
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final qty = int.tryParse(_ctrl.text.trim()) ?? 0;
    if (qty <= 0) {
      setState(() => _error = 'Enter a quantity greater than 0.');
      return;
    }
    Navigator.of(context).pop(qty);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        context.getRSize(20) + context.deviceBottomPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: context.getRSize(40),
              height: context.getRSize(4),
              decoration: BoxDecoration(
                color: t.dividerColor,
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
              ),
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          Text(
            widget.productName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context
                .boldStyle(17)
                .copyWith(color: t.colorScheme.onSurface),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            '${widget.sourceStoreName} has ${widget.available}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.regularStyle(13).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(16)),
          AppInput(
            key: StockRequestQuantitySheetKeys.field,
            controller: _ctrl,
            labelText: 'Quantity to request',
            autofocus: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onFieldSubmitted: (_) => _save(),
          ),
          if (_error != null) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              _error!,
              style: context
                  .regularStyle(12)
                  .copyWith(color: t.colorScheme.error),
            ),
          ],
          SizedBox(height: context.getRSize(20)),
          AppButton(
            key: StockRequestQuantitySheetKeys.save,
            text: 'Set quantity',
            icon: AppIcons.check,
            isFullWidth: true,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
