import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/section_header.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_parts.dart';

class EditReceiveItemModal extends ConsumerStatefulWidget {
  final ReceiveCartLine item;

  const EditReceiveItemModal({super.key, required this.item});

  static Future<void> show(BuildContext context, ReceiveCartLine item) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Centred and at most 640dp wide on tablets and wide screens (#394).
      constraints: const BoxConstraints(maxWidth: kReceiveSheetMaxWidth),
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
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final scheme = t.extension<AppSchemeColors>();
    final text = t.colorScheme.onSurface;
    final muted = t.textTheme.bodySmall?.color ?? text;
    final primary = t.colorScheme.primary;
    final primaryTint = scheme?.primaryTint ?? f.infoTint;

    final editBuyingPermission = Gates.editBuyingPrice.allows(ref);
    final editPricePermission = Gates.editProductPrice.allows(ref);

    final rawQty = int.tryParse(_qtyCtrl.text) ?? 1;
    final buyingVal =
        double.tryParse(_buyingCtrl.text.replaceAll(',', '')) ?? 0.0;
    final buyingKobo = (buyingVal * 100).round();
    final lineTotalKobo = buyingKobo * rawQty;

    Widget currencyPrefix(bool enabled) => Padding(
      padding: EdgeInsets.all(context.getRSize(14)),
      child: Text(
        activeCurrencySymbol,
        style: context
            .boldStyle(16)
            .copyWith(color: enabled ? text : muted.withValues(alpha: 0.5)),
      ),
    );

    return Container(
      key: ReceiveKeys.editSheet,
      constraints: BoxConstraints(maxHeight: context.screenHeight * 0.9),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppSpacing.borderRadiusXL),
        ),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(12),
          context.getRSize(20),
          context.deviceBottomPadding + context.getRSize(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ReceiveSheetHandle(),
            SizedBox(height: context.getRSize(16)),

            // Header: tile, title, product name, close.
            Row(
              children: [
                IconTile(
                  icon: AppIcons.box,
                  tint: primaryTint,
                  iconColor: primary,
                  size: 44,
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Edit Quantity & Prices',
                        style: context.screenTitleStyle.copyWith(color: text),
                      ),
                      Text(
                        widget.item.productName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context
                            .semiBoldStyle(14)
                            .copyWith(color: primary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ReceiveKeys.editClose,
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  constraints: const BoxConstraints(
                    minWidth: kMinInteractiveDimension,
                    minHeight: kMinInteractiveDimension,
                  ),
                  onPressed: () => Navigator.pop(context),
                  icon: AppIcon(
                    AppIcons.close,
                    size: context.getRSize(22),
                    color: muted,
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(20)),

            // Quantity: − / field / +.
            Container(
              padding: EdgeInsets.all(context.getRSize(10)),
              decoration: AppDecorations.card(context),
              child: Row(
                children: [
                  _qtyBtn(
                    key: ReceiveKeys.editMinus,
                    icon: AppIcons.minus,
                    tooltip: 'Decrease',
                    fill: f.dangerTint,
                    ink: f.danger,
                    onTap: () => _updateQty(-1),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
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
                      style: context
                          .extraBoldStyle(28)
                          .copyWith(color: primary),
                      border: InputBorder.none,
                      fillColor: Colors.transparent,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  _qtyBtn(
                    key: ReceiveKeys.editPlus,
                    icon: AppIcons.add,
                    tooltip: 'Increase',
                    fill: f.greenTint,
                    ink: f.green,
                    onTap: () => _updateQty(1),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.getRSize(20)),

            // Prices.
            const SectionHeader(
              title: 'UPDATE PRICES',
              variant: SectionHeaderVariant.group,
            ),
            SizedBox(height: context.getRSize(10)),

            AppInput(
              controller: _buyingCtrl,
              enabled: editBuyingPermission,
              labelText: 'Unit Cost (Buying Price)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter(grouping: true)],
              prefixIcon: currencyPrefix(editBuyingPermission),
            ),

            // Inline Uncosted warning (#199 / PRD #155 US 37). A blank/0 unit
            // cost is allowed — the receipt still commits — but it must not be
            // silent: no payable is raised for these units and they later sell
            // at 0 COGS. Save Changes stays enabled.
            if (editBuyingPermission && buyingKobo == 0)
              Padding(
                padding: EdgeInsets.only(
                  top: context.getRSize(6),
                  left: context.getRSize(4),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppIcon(
                      AppIcons.warning,
                      size: context.getRSize(14),
                      color: f.warning,
                    ),
                    SizedBox(width: context.getRSize(6)),
                    Expanded(
                      child: Text(
                        'No buying price. Add what you paid so profit shows '
                        'correctly. You can add it later.',
                        style: context
                            .regularStyle(12)
                            .copyWith(color: f.warning),
                      ),
                    ),
                  ],
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
              prefixIcon: currencyPrefix(editPricePermission),
            ),
            if (!businessSellsOnePrice(ref.watch(currentBusinessProvider))) ...[
              SizedBox(height: context.getRSize(16)),
              AppInput(
                controller: _wholesaleCtrl,
                enabled: editPricePermission,
                labelText: 'Wholesale Price',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter(grouping: true)],
                prefixIcon: currencyPrefix(editPricePermission),
              ),
            ],

            if (lineTotalKobo > 0) ...[
              SizedBox(height: context.getRSize(20)),
              Container(
                padding: EdgeInsets.all(context.getRSize(16)),
                decoration: BoxDecoration(
                  color: primaryTint,
                  borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Total Cost',
                        style: context
                            .semiBoldStyle(16)
                            .copyWith(color: primary),
                      ),
                    ),
                    Text(
                      formatCurrency(lineTotalKobo / 100.0),
                      style: context.boldStyle(18).copyWith(color: primary),
                    ),
                  ],
                ),
              ),
            ],

            SizedBox(height: context.getRSize(24)),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: AppButton(
                    text: 'Remove',
                    variant: AppButtonVariant.danger,
                    icon: AppIcons.delete,
                    onPressed: () {
                      ref
                          .read(receiveCartProvider.notifier)
                          .remove(widget.item.productId);
                      Navigator.pop(context);
                    },
                  ),
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  flex: 3,
                  child: AppButton(
                    text: 'Save Changes',
                    variant: AppButtonVariant.primary,
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

                        // One-price shop (#493): the Wholesale box is hidden,
                        // so the line keeps the product's saved wholesale price
                        // untouched (never overwritten with retail).
                        final sellsOnePrice = businessSellsOnePrice(
                          ref.read(currentBusinessProvider),
                        );
                        if (!sellsOnePrice) {
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

  /// A 48dp+ quantity button: a tinted rounded square with the icon.
  Widget _qtyBtn({
    required Key key,
    required IconData icon,
    required String tooltip,
    required Color fill,
    required Color ink,
    required VoidCallback onTap,
  }) {
    final side = context.getRSize(52) < kMinInteractiveDimension
        ? kMinInteractiveDimension
        : context.getRSize(52);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: fill,
        borderRadius: radius,
        child: InkWell(
          key: key,
          onTap: onTap,
          borderRadius: radius,
          child: SizedBox(
            width: side,
            height: side,
            child: Center(
              child: AppIcon(icon, color: ink, size: context.getRSize(22)),
            ),
          ),
        ),
      ),
    );
  }
}
