import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

class EditItemModal extends ConsumerStatefulWidget {
  final Map<String, dynamic> item;

  const EditItemModal({super.key, required this.item});

  @override
  ConsumerState<EditItemModal> createState() => _EditItemModalState();

  /// Returns the removed line map when the user taps Remove (so the caller can
  /// offer Undo, §13.2), or null on save/dismiss.
  static Future<Map<String, dynamic>?> show(
    BuildContext context,
    Map<String, dynamic> item,
  ) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => EditItemModal(item: item),
    );
  }
}

class _EditItemModalState extends ConsumerState<EditItemModal> {
  late TextEditingController _qtyCtrl;
  late TextEditingController _discountCtrl;
  // 'percent' (default) | 'naira' — §13.2.
  late String _discountKind;

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(text: widget.item['qty'].toString());

    final existingValue = (widget.item['discountValue'] as num?) ?? 0;
    _discountKind =
        (widget.item['discountKind'] as String?) == 'naira' ? 'naira' : 'percent';
    _discountCtrl = TextEditingController(
      text: existingValue > 0 ? _trimNum(existingValue) : '',
    );
    _qtyCtrl.addListener(_onInputChanged);
    _discountCtrl.addListener(_onInputChanged);

    // Auto-highlight text and show keyboard
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _qtyCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _qtyCtrl.text.length,
      );
    });
  }

  void _onInputChanged() => setState(() {});

  /// Formats a number without trailing `.0` for display in the input.
  static String _trimNum(num n) =>
      n == n.toInt() ? n.toInt().toString() : n.toString();

  @override
  void dispose() {
    _qtyCtrl.removeListener(_onInputChanged);
    _discountCtrl.removeListener(_onInputChanged);
    _qtyCtrl.dispose();
    _discountCtrl.dispose();
    super.dispose();
  }

  void _updateQty(double delta) {
    final v = double.tryParse(_qtyCtrl.text) ?? 1.0;
    final newValue = (v + delta).clamp(0.5, 999.0);
    setState(() {
      _qtyCtrl.text = newValue.toStringAsFixed(
        newValue == newValue.toInt() ? 0 : 1,
      );
    });
    // Re-select text after manual update via buttons
    _qtyCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _qtyCtrl.text.length,
    );
  }

  /// Resolves the live discount for the current inputs. Clamps to the role's
  /// max percentage (§13.2) and never below zero / above the line total.
  ({int discountKobo, bool cappedByRole}) _resolveDiscount({
    required int lineTotalKobo,
    required int maxPercent,
  }) {
    final entered = double.tryParse(_discountCtrl.text.trim()) ?? 0.0;
    if (entered <= 0 || lineTotalKobo <= 0) {
      return (discountKobo: 0, cappedByRole: false);
    }
    final rawKobo = _discountKind == 'percent'
        ? (lineTotalKobo * entered / 100).round()
        : (entered * 100).round();
    final capKobo = (lineTotalKobo * maxPercent / 100).round();
    final cappedByRole = rawKobo > capKobo;
    final discountKobo = rawKobo.clamp(0, capKobo);
    return (discountKobo: discountKobo, cappedByRole: cappedByRole);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final border = t.dividerColor;
    final text = t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;

    final maxPercent = ref.watch(currentUserMaxDiscountPercentProvider);
    final canDiscount = maxPercent > 0;
    final qty = double.tryParse(_qtyCtrl.text) ?? 1.0;
    final unitPriceKobo = (widget.item['unitPriceKobo'] as num).toInt();
    final lineTotalKobo = (unitPriceKobo * qty).round();
    final resolved =
        _resolveDiscount(lineTotalKobo: lineTotalKobo, maxPercent: maxPercent);

    // Auto-snap the percent input to the role cap when exceeded (§13.2).
    if (resolved.cappedByRole && _discountKind == 'percent') {
      final capText = maxPercent.toString();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _discountCtrl.text == capText) return;
        _discountCtrl.text = capText;
        _discountCtrl.selection =
            TextSelection.collapsed(offset: capText.length);
      });
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(24),
        context.getRSize(16),
        context.getRSize(24),
        context.bottomInset + context.getRSize(24),
      ),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
                  FontAwesomeIcons.pills,
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
                      'Edit Quantity',
                      style: TextStyle(
                        fontSize: context.getRFontSize(20),
                        fontWeight: FontWeight.w900,
                        color: text,
                        letterSpacing: -0.5,
                      ),
                    ),
                    Text(
                      widget.item['name'],
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
                  FontAwesomeIcons.minus,
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
                        decimal: true,
                      ),
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
                  FontAwesomeIcons.plus,
                  () => _updateQty(1),
                  color: Colors.green,
                ),
              ],
            ),
          ),
          // Micro-adjustment chips — only when the product allows
          // fractional sales (§13.2). Hidden entirely otherwise.
          if (widget.item['allowFractionalSales'] == true) ...[
            SizedBox(height: context.getRSize(12)),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _microAdjustChip('-0.5', () => _updateQty(-0.5)),
                SizedBox(width: context.getRSize(12)),
                _microAdjustChip('+0.5', () => _updateQty(0.5)),
              ],
            ),
          ],

          SizedBox(height: context.getRSize(28)),

          // ── Apply Discount (§13.2) ────────────────────────────────────────
          _discountSection(
            canDiscount: canDiscount,
            maxPercent: maxPercent,
            lineTotalKobo: lineTotalKobo,
            discountKobo: resolved.discountKobo,
            cappedByRole: resolved.cappedByRole,
          ),

          SizedBox(height: context.getRSize(32)),

          // Action Buttons
          Row(
            children: [
              Expanded(
                flex: 2,
                child: AppButton(
                  text: 'Remove',
                  variant: AppButtonVariant.danger,
                  icon: FontAwesomeIcons.trashCan,
                  height: context.getRSize(56),
                  onPressed: () {
                    ref.read(cartProvider).removeItem(widget.item['name']);
                    // Return the removed line so the cart can offer Undo.
                    Navigator.pop(context, widget.item);
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
                    final cart = ref.read(cartProvider);
                    final qty = double.tryParse(_qtyCtrl.text) ?? 1.0;
                    cart.updateQty(widget.item['name'], qty);
                    // Persist the resolved (role-capped) discount alongside qty.
                    final entered =
                        double.tryParse(_discountCtrl.text.trim()) ?? 0.0;
                    cart.setLineDiscount(
                      widget.item['name'],
                      kind: _discountKind,
                      enteredValue: entered,
                      discountKobo: resolved.discountKobo,
                    );
                    Navigator.pop(context);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _discountSection({
    required bool canDiscount,
    required int maxPercent,
    required int lineTotalKobo,
    required int discountKobo,
    required bool cappedByRole,
  }) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final border = t.dividerColor;

    // Cashier (or any role capped at 0%): blocked entirely (§13.2).
    if (!canDiscount) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: BoxDecoration(
          color: border.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            Icon(
              FontAwesomeIcons.lock,
              size: context.getRSize(14),
              color: text.withValues(alpha: 0.45),
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: Text(
                'Discounts not allowed at your role. Ask Manager.',
                style: TextStyle(
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.w600,
                  color: text.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final newLineTotal = lineTotalKobo - discountKobo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'APPLY DISCOUNT',
          style: TextStyle(
            fontSize: context.getRFontSize(12),
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: text.withValues(alpha: 0.5),
          ),
        ),
        SizedBox(height: context.getRSize(10)),
        Row(
          children: [
            _kindChip('%', 'percent'),
            SizedBox(width: context.getRSize(8)),
            _kindChip('₦', 'naira'),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: AppInput(
                controller: _discountCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                hintText: _discountKind == 'percent' ? '0%' : '₦0',
              ),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(10)),
        if (discountKobo > 0)
          Text(
            'Saving ${formatCurrency(discountKobo / 100.0)} — '
            'new line total: ${formatCurrency(newLineTotal / 100.0)}',
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w700,
              color: Colors.green.shade600,
            ),
          ),
        if (cappedByRole)
          Padding(
            padding: EdgeInsets.only(top: context.getRSize(4)),
            child: Text(
              'Maximum discount is $maxPercent%. Capped.',
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                fontWeight: FontWeight.w600,
                color: Colors.orange.shade700,
              ),
            ),
          ),
      ],
    );
  }

  Widget _kindChip(String label, String kind) {
    final t = Theme.of(context);
    final selected = _discountKind == kind;
    final primary = t.colorScheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _discountKind = kind),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: context.getRSize(44),
          height: context.getRSize(44),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? primary.withValues(alpha: 0.12)
                : t.dividerColor.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? primary.withValues(alpha: 0.5)
                  : t.dividerColor.withValues(alpha: 0.15),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(16),
              fontWeight: FontWeight.w800,
              color: selected ? primary : t.colorScheme.onSurface.withValues(
                alpha: 0.6,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _qtyBtn(IconData icon, VoidCallback onTap, {required Color color}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: context.getRSize(60),
          height: context.getRSize(60),
          decoration: BoxDecoration(
            color: color.withValues(alpha: isDark ? 0.15 : 0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
          ),
          child: Icon(icon, size: context.getRSize(20), color: color),
        ),
      ),
    );
  }

  Widget _microAdjustChip(String label, VoidCallback onTap) {
    final t = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(16),
            vertical: context.getRSize(8),
          ),
          decoration: BoxDecoration(
            color: t.dividerColor.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.dividerColor.withValues(alpha: 0.1)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w700,
              color: t.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}
