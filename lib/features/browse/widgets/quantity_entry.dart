import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

// Quantity entry for the Shopper cart (#426): a stepper that moves by the
// product's order step (#473) and a pop-up to type a number.

/// − [qty] + with the product's step. Tapping the number opens a pop-up to
/// type a quantity.
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.quantity,
    required this.onChanged,
    required this.onType,
    this.step = 1,
    this.min = 1,
    this.max,
  });

  final int quantity;
  final int step;
  final int min;
  final int? max;
  final ValueChanged<int> onChanged;
  final VoidCallback onType;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final canLower = quantity - step >= min;
    final canRaise = max == null || quantity + step <= max!;
    Widget button(IconData icon, String tip, VoidCallback? onTap) =>
        SizedBox.square(
          dimension: kMinInteractiveDimension,
          child: IconButton(
            tooltip: tip,
            onPressed: onTap,
            icon: AppIcon(icon, size: context.getRSize(20)),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: t.dividerColor),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(
            AppIcons.minus,
            'Fewer',
            canLower ? () => onChanged(quantity - step) : null,
          ),
          InkWell(
            key: const Key('shopper-qty-value'),
            onTap: onType,
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: context.getRSize(40),
                minHeight: kMinInteractiveDimension,
              ),
              child: Center(
                child: Text(
                  '$quantity',
                  style: context
                      .boldStyle(16)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
            ),
          ),
          button(
            AppIcons.add,
            'More',
            canRaise ? () => onChanged(quantity + step) : null,
          ),
        ],
      ),
    );
  }
}

/// Asks for a quantity. [validate] returns a problem message, or null when
/// the number is allowed. Returns the chosen quantity, or null if cancelled.
Future<int?> showQuantityDialog(
  BuildContext context, {
  required int initial,
  required String? Function(int qty) validate,
  String? hint,
}) => showDialog<int>(
  context: context,
  builder: (_) =>
      _QuantityDialog(initial: initial, validate: validate, hint: hint),
);

class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({
    required this.initial,
    required this.validate,
    this.hint,
  });

  final int initial;
  final String? Function(int qty) validate;
  final String? hint;

  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  late final _controller = TextEditingController(text: '${widget.initial}');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final qty = int.tryParse(_controller.text.trim());
    final problem = qty == null ? 'Type a whole number' : widget.validate(qty);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(qty);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: const Text('How many?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.hint != null) ...[
            Text(widget.hint!, style: context.regularStyle(13)),
            SizedBox(height: context.getRSize(8)),
          ],
          AppInput(
            key: const Key('shopper-qty-input'),
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              _error!,
              key: const Key('shopper-qty-error'),
              style: context
                  .semiBoldStyle(13)
                  .copyWith(color: t.colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          isFullWidth: false,
          onPressed: () => Navigator.of(context).pop(),
        ),
        AppButton(text: 'Set', isFullWidth: false, onPressed: _submit),
      ],
    );
  }
}
