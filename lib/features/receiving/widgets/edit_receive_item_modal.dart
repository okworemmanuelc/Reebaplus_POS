import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

class EditReceiveItemModal extends ConsumerStatefulWidget {
  final ReceiveCartLine item;

  const EditReceiveItemModal({super.key, required this.item});

  static Future<void> show(BuildContext context, ReceiveCartLine item) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => EditReceiveItemModal(item: item),
    );
  }

  @override
  ConsumerState<EditReceiveItemModal> createState() =>
      _EditReceiveItemModalState();
}

class _EditReceiveItemModalState extends ConsumerState<EditReceiveItemModal> {
  late TextEditingController _qtyCtrl;
  late TextEditingController _buyingCtrl;
  late TextEditingController _retailCtrl;
  late TextEditingController _wholesaleCtrl;

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(text: widget.item.qty.toString());
    _buyingCtrl = TextEditingController(
      text: _trimNum(widget.item.buyingPriceKobo / 100),
    );
    _retailCtrl = TextEditingController(
      text: _trimNum(widget.item.retailKobo / 100),
    );
    _wholesaleCtrl = TextEditingController(
      text: _trimNum(widget.item.wholesaleKobo / 100),
    );

    _qtyCtrl.addListener(_onInputChanged);
    _buyingCtrl.addListener(_onInputChanged);
    _retailCtrl.addListener(_onInputChanged);
    _wholesaleCtrl.addListener(_onInputChanged);

    // Auto-highlight qty text and show keyboard if desired
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _qtyCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _qtyCtrl.text.length,
      );
    });
  }

  void _onInputChanged() => setState(() {});

  static String _trimNum(num n) =>
      n == n.toInt() ? n.toInt().toString() : n.toString();

  @override
  void dispose() {
    _qtyCtrl.removeListener(_onInputChanged);
    _buyingCtrl.removeListener(_onInputChanged);
    _retailCtrl.removeListener(_onInputChanged);
    _wholesaleCtrl.removeListener(_onInputChanged);

    _qtyCtrl.dispose();
    _buyingCtrl.dispose();
    _retailCtrl.dispose();
    _wholesaleCtrl.dispose();
    super.dispose();
  }

  void _updateQty(int delta) {
    final v = int.tryParse(_qtyCtrl.text) ?? 1;
    final newValue = (v + delta).clamp(1, 10000);
    setState(() {
      _qtyCtrl.text = newValue.toString();
    });
    _qtyCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _qtyCtrl.text.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final border = t.dividerColor;
    final text = t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;

    final editBuyingPermission = Gates.editBuyingPrice.allows(ref);
    final editPricePermission = Gates.editProductPrice.allows(ref);

    final rawQty = int.tryParse(_qtyCtrl.text) ?? 1;
    final buyingVal =
        double.tryParse(_buyingCtrl.text.replaceAll(',', '')) ?? 0.0;
    final buyingKobo = (buyingVal * 100).round();
    final lineTotalKobo = buyingKobo * rawQty;

    return Container(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(24),
          context.getRSize(16),
          context.getRSize(24),
          context.deviceBottomPadding + context.getRSize(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag Handle
            Center(
              child: Container(
                width: context.getRSize(40),
                height: context.getRSize(4),
                decoration: BoxDecoration(
                  color: border.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(24)),

            // Header with Icon
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(context.getRSize(14)),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        primary.withValues(alpha: 0.2),
                        primary.withValues(alpha: 0.1),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    FontAwesomeIcons.boxOpen.data,
                    size: context.getRSize(20),
                    color: primary,
                  ),
                ),
                SizedBox(width: context.getRSize(16)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Edit Quantity & Prices',
                        style: TextStyle(
                          fontSize: context.getRFontSize(20),
                          fontWeight: FontWeight.w900,
                          color: text,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Text(
                        widget.item.productName,
                        style: TextStyle(
                          fontSize: context.getRFontSize(14),
                          color: text.withValues(alpha: 0.5),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Material(
                  color: border.withValues(alpha: 0.1),
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(
                      Icons.close,
                      size: context.getRSize(20),
                      color: text.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(32)),

            // Premium Quantity Selector
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(12),
                vertical: context.getRSize(12),
              ),
              decoration: BoxDecoration(
                color: t.colorScheme.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: border.withValues(alpha: 0.6),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: primary.withValues(alpha: 0.05),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Row(
                children: [
                  _qtyBtn(
                    FontAwesomeIcons.minus.data,
                    () => _updateQty(-1),
                    color: Colors.red,
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        vertical: context.getRSize(4),
                      ),
                      decoration: BoxDecoration(
                        color: border.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: AppInput(
                        controller: _qtyCtrl,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: false,
                        ),
                        inputFormatters: [
                          CurrencyInputFormatter(grouping: false),
                        ],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.getRFontSize(32),
                          fontWeight: FontWeight.w900,
                          color: primary,
                          letterSpacing: 1,
                        ),
                        border: InputBorder.none,
                        fillColor: Colors.transparent,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  _qtyBtn(
                    FontAwesomeIcons.plus.data,
                    () => _updateQty(1),
                    color: Colors.green,
                  ),
                ],
              ),
            ),
            SizedBox(height: context.getRSize(28)),

            // Prices Section
            Text(
              'UPDATE PRICES',
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: text.withValues(alpha: 0.5),
              ),
            ),
            SizedBox(height: context.getRSize(12)),

            AppInput(
              controller: _buyingCtrl,
              enabled: editBuyingPermission,
              labelText: 'Unit Cost (Buying Price)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter(grouping: true)],
              prefixIcon: Padding(
                padding: EdgeInsets.all(context.getRSize(14)),
                child: Text(
                  activeCurrencySymbol,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: editBuyingPermission
                        ? text
                        : text.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(16)),

            AppInput(
              controller: _retailCtrl,
              enabled: editPricePermission,
              labelText: 'Retail Price',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter(grouping: true)],
              prefixIcon: Padding(
                padding: EdgeInsets.all(context.getRSize(14)),
                child: Text(
                  activeCurrencySymbol,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: editPricePermission
                        ? text
                        : text.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(16)),

            AppInput(
              controller: _wholesaleCtrl,
              enabled: editPricePermission,
              labelText: 'Wholesale Price',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter(grouping: true)],
              prefixIcon: Padding(
                padding: EdgeInsets.all(context.getRSize(14)),
                child: Text(
                  activeCurrencySymbol,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: editPricePermission
                        ? text
                        : text.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),

            if (lineTotalKobo > 0) ...[
              SizedBox(height: context.getRSize(24)),
              Container(
                padding: EdgeInsets.all(context.getRSize(16)),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total Cost',
                      style: TextStyle(
                        fontSize: context.getRFontSize(16),
                        fontWeight: FontWeight.w600,
                        color: primary,
                      ),
                    ),
                    Text(
                      formatCurrency(lineTotalKobo / 100.0),
                      style: TextStyle(
                        fontSize: context.getRFontSize(18),
                        fontWeight: FontWeight.w800,
                        color: primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            SizedBox(height: context.getRSize(32)),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: AppButton(
                    text: 'Remove',
                    variant: AppButtonVariant.danger,
                    icon: FontAwesomeIcons.trashCan.data,
                    height: context.getRSize(56),
                    onPressed: () {
                      ref
                          .read(receiveCartProvider.notifier)
                          .remove(widget.item.productId);
                      Navigator.pop(context);
                    },
                  ),
                ),
                SizedBox(width: context.getRSize(16)),
                Expanded(
                  flex: 3,
                  child: AppButton(
                    text: 'Save Changes',
                    variant: AppButtonVariant.primary,
                    height: context.getRSize(56),
                    onPressed: () {
                      final notifier = ref.read(receiveCartProvider.notifier);

                      final qty = int.tryParse(_qtyCtrl.text) ?? 1;
                      notifier.setQty(widget.item.productId, qty);

                      if (editBuyingPermission) {
                        final b =
                            double.tryParse(
                              _buyingCtrl.text.replaceAll(',', ''),
                            ) ??
                            0.0;
                        notifier.setBuyingPrice(
                          widget.item.productId,
                          (b * 100).round(),
                        );
                      }

                      if (editPricePermission) {
                        final r =
                            double.tryParse(
                              _retailCtrl.text.replaceAll(',', ''),
                            ) ??
                            0.0;
                        notifier.setRetailPrice(
                          widget.item.productId,
                          (r * 100).round(),
                        );

                        final w =
                            double.tryParse(
                              _wholesaleCtrl.text.replaceAll(',', ''),
                            ) ??
                            0.0;
                        notifier.setWholesalePrice(
                          widget.item.productId,
                          (w * 100).round(),
                        );
                      }

                      Navigator.pop(context);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _qtyBtn(IconData icon, VoidCallback onTap, {required Color color}) {
    return Material(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: context.getRSize(56),
          height: context.getRSize(56),
          alignment: Alignment.center,
          child: Icon(icon, color: color, size: context.getRSize(20)),
        ),
      ),
    );
  }
}
