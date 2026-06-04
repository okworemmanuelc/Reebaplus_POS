import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';

class QuickSaleModal extends ConsumerStatefulWidget {
  final Color surfaceCol;
  final Color textCol;
  final Color subtextCol;
  final Color cardCol;
  final bool isDark;

  const QuickSaleModal({
    super.key,
    required this.surfaceCol,
    required this.textCol,
    required this.subtextCol,
    required this.cardCol,
    required this.isDark,
  });

  @override
  ConsumerState<QuickSaleModal> createState() => _QuickSaleModalState();
}

class _QuickSaleModalState extends ConsumerState<QuickSaleModal> {
  final _nameCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: widget.surfaceCol,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(
        'Quick Sale ⚡',
        style: TextStyle(color: widget.textCol, fontWeight: FontWeight.bold),
      ),
      // Scrolls so the three fields + actions never overflow the dialog when
      // the keyboard shrinks the available height on small screens.
      content: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppInput(
            controller: _nameCtrl,
            labelText: 'Item Name',
            prefixIcon: Icon(FontAwesomeIcons.tag, size: context.getRSize(16)),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            controller: _qtyCtrl,
            labelText: 'Quantity',
            prefixIcon: Icon(
              FontAwesomeIcons.cubes,
              size: context.getRSize(16),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            controller: _priceCtrl,
            labelText: 'Price Per Unit ($activeCurrencySymbol)',
            hintText: 'e.g. 500',
            prefixIcon: Icon(
              FontAwesomeIcons.nairaSign,
              size: context.getRSize(16),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
        ],
      ),
      ),
      actions: [
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          isFullWidth: false,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          text: 'Send to Cart',
          variant: AppButtonVariant.primary,
          isFullWidth: false,
          onPressed: () {
            if (_nameCtrl.text.isNotEmpty &&
                _qtyCtrl.text.isNotEmpty &&
                _priceCtrl.text.isNotEmpty) {
              final price = parseCurrency(_priceCtrl.text);
              final product = {
                'name': _nameCtrl.text,
                'subtitle': 'Quick Sale',
                'price': price,
                'icon': FontAwesomeIcons.bolt,
                'color': Theme.of(context).colorScheme.primary,
                'category': 'Other',
              };
              ref
                  .read(cartProvider)
                  .addItem(product, qty: double.tryParse(_qtyCtrl.text) ?? 1.0);
              Navigator.pop(context);
            } else {
              AppNotification.showError(
                context,
                'Item Name, Quantity, and Price are required.',
              );
            }
          },
        ),
      ],
    );
  }
}
