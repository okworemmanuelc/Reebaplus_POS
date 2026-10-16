import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/features/pos/widgets/sales_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

class EditItemModal extends ConsumerStatefulWidget {
  final Map<String, dynamic> item;

  /// When non-null the modal runs in "add to cart" mode: the primary button
  /// adds [newProduct] (with the chosen qty + discount) instead of editing an
  /// existing cart line. Backs the long-press flow on the POS product grid.
  final ProductData? newProduct;
  final int maxStock;
  final PriceTier tier;

  /// Add mode only: start the quantity field on the cart total + 1 (capped at
  /// [maxStock]) instead of on the cart total. A barcode scan means "one more"
  /// (#317); tap-and-hold keeps starting on what's already in the cart.
  final bool shouldStartOnNextUnit;

  const EditItemModal({
    super.key,
    required this.item,
    this.newProduct,
    this.maxStock = 1 << 30,
    this.tier = PriceTier.retailer,
    this.shouldStartOnNextUnit = false,
  });

  bool get isNew => newProduct != null;

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

  /// Opens the modal in "add to cart" mode for a product on the POS grid.
  /// Returns true if the requested qty was fully accepted, false if it was
  /// clamped / rejected by stock, or null if the user dismissed without adding.
  /// The barcode scan path (#317) passes [shouldStartOnNextUnit].
  static Future<bool?> showForProduct(
    BuildContext context, {
    required ProductData product,
    required int maxStock,
    required PriceTier tier,
    bool shouldStartOnNextUnit = false,
  }) {
    final unitPriceKobo = tier == PriceTier.wholesaler
        ? product.wholesalerPriceKobo
        : product.retailerPriceKobo;
    // Synthetic line shaped like a cart map so the build() reads below work
    // unchanged. Only the fields the modal reads are needed.
    final item = <String, dynamic>{
      'id': product.id,
      'name': product.name,
      'qty': 1,
      'unitPriceKobo': unitPriceKobo,
      'catalogPriceKobo': unitPriceKobo,
      'customPriceKobo': null,
      'discountKind': null,
      'discountValue': 0.0,
      'allowFractionalSales': product.allowFractionalSales,
    };
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => EditItemModal(
        item: item,
        newProduct: product,
        maxStock: maxStock,
        tier: tier,
        shouldStartOnNextUnit: shouldStartOnNextUnit,
      ),
    );
  }
}

class _EditItemModalState extends ConsumerState<EditItemModal> {
  late TextEditingController _qtyCtrl;
  late TextEditingController _discountCtrl;
  // Custom unit price field (§13.4) — empty when the line uses the catalog
  // price; gated on `sales.set_custom_price`.
  late TextEditingController _customPriceCtrl;
  // 'percent' (default) | 'naira' — §13.2.
  late String _discountKind;
  // Add mode: how many of the product the cart held when the sheet opened.
  // Drives the start value and the "N already in cart" line (#317).
  late final double _inCartAtOpen;

  @override
  void initState() {
    super.initState();
    _inCartAtOpen = widget.isNew ? _cartQtyOf(widget.newProduct!.id) : 0;
    _qtyCtrl = TextEditingController(text: _initialQtyText());

    final existingValue = (widget.item['discountValue'] as num?) ?? 0;
    _discountKind = (widget.item['discountKind'] as String?) == 'naira'
        ? 'naira'
        : 'percent';
    _discountCtrl = TextEditingController(
      text: existingValue > 0 ? _trimNum(existingValue) : '',
    );
    final existingCustomKobo = widget.item['customPriceKobo'] as int?;
    _customPriceCtrl = TextEditingController(
      text: (existingCustomKobo != null && existingCustomKobo > 0)
          ? _trimNum(existingCustomKobo / 100.0)
          : '',
    );
    _qtyCtrl.addListener(_onInputChanged);
    _discountCtrl.addListener(_onInputChanged);
    _customPriceCtrl.addListener(_onInputChanged);

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

  /// Upper bound for the quantity field: the product's available stock — the
  /// count shown on the POS card. Quantity can never go above this. In add
  /// mode that's the card stock; in edit mode it's the line's stored max stock.
  double get _maxQty => widget.isNew
      ? widget.maxStock.toDouble()
      : (((widget.item['maxStock'] as int?) ?? (1 << 30)).toDouble());

  /// Total quantity of [productId] across the cart's lines.
  double _cartQtyOf(String productId) => ref
      .read(cartProvider)
      .value
      .where((i) => i['id'] == productId)
      .fold<double>(0, (s, i) => s + (i['qty'] as num).toDouble());

  /// Initial quantity text. Add mode shows the product's current cart quantity
  /// (so the field is the new total, capped at stock) or 1 if it isn't in the
  /// cart yet; edit mode shows the existing line quantity. A scan
  /// ([EditItemModal.shouldStartOnNextUnit], #317) starts one above the cart
  /// total instead, still capped at stock — the field keeps meaning "total".
  String _initialQtyText() {
    if (!widget.isNew) return widget.item['qty'].toString();
    if (widget.shouldStartOnNextUnit) {
      final next = _inCartAtOpen + 1;
      return _trimNum(next > _maxQty ? _maxQty : next);
    }
    return _trimNum(_inCartAtOpen > 0 ? _inCartAtOpen : 1.0);
  }

  @override
  void dispose() {
    _qtyCtrl.removeListener(_onInputChanged);
    _discountCtrl.removeListener(_onInputChanged);
    _customPriceCtrl.removeListener(_onInputChanged);
    _qtyCtrl.dispose();
    _discountCtrl.dispose();
    _customPriceCtrl.dispose();
    super.dispose();
  }

  void _updateQty(double delta) {
    final v = double.tryParse(_qtyCtrl.text) ?? 1.0;
    final upper = _maxQty < 0.5 ? 0.5 : _maxQty;
    final newValue = (v + delta).clamp(0.5, upper);
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

  /// The typed discount: a ₦ amount reads like every money field (commas
  /// allowed, #401); a percentage keeps its plain number parse.
  double _enteredDiscount() {
    final t = _discountCtrl.text.trim();
    return _discountKind == 'naira'
        ? parseCurrency(t)
        : (double.tryParse(t) ?? 0.0);
  }

  /// Resolves the live discount for the current inputs. Clamps to the role's
  /// max percentage (§13.2) and never below zero / above the line total.
  ({int discountKobo, bool cappedByRole}) _resolveDiscount({
    required int lineTotalKobo,
    required int maxPercent,
  }) {
    final entered = _enteredDiscount();
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
    final text = t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;

    final maxPercent = ref.watch(currentUserMaxDiscountPercentProvider);
    final canDiscount = maxPercent > 0;
    final canSetCustomPrice = Gates.setCustomPrice.allows(ref);
    // Designated selling price for the line — the immutable catalog reference.
    final catalogUnitPriceKobo =
        (widget.item['catalogPriceKobo'] as int?) ??
        (widget.item['unitPriceKobo'] as num).toInt();
    // Live custom price typed into the field (kobo). Only honoured when the
    // user holds the permission; a non-positive entry means "no override".
    final customEntered = parseCurrency(_customPriceCtrl.text.trim());
    final customKobo = (customEntered * 100).round();
    final hasCustomPrice = canSetCustomPrice && customKobo > 0;

    // Define the custom price floor
    final floorKobo = (catalogUnitPriceKobo * (100 - maxPercent) / 100.0)
        .round();

    // Auto-snap the custom price input to the floor when custom price is below floor.
    if (hasCustomPrice && customKobo < floorKobo) {
      final snapText = _trimNum(floorKobo / 100.0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _customPriceCtrl.text == snapText) return;
        _customPriceCtrl.text = snapText;
        _customPriceCtrl.selection = TextSelection.collapsed(
          offset: snapText.length,
        );
      });
    }

    final rawQty = double.tryParse(_qtyCtrl.text) ?? 1.0;
    // Quantity can't exceed available stock (the POS card count). Snap an
    // over-limit entry back down to the cap, same pattern as the discount cap.
    if (rawQty > _maxQty) {
      final capText = _trimNum(_maxQty);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _qtyCtrl.text == capText) return;
        _qtyCtrl.text = capText;
        _qtyCtrl.selection = TextSelection.collapsed(offset: capText.length);
      });
    }
    final qty = rawQty > _maxQty ? _maxQty : rawQty;
    // Effective unit price = the typed custom price (when permitted) else the
    // catalog price. Clamp to floorKobo to prevent temporary sub-floor math.
    // Drives the line total, the discount cap, and the order.
    final effectiveCustomKobo = hasCustomPrice
        ? (customKobo < floorKobo ? floorKobo : customKobo)
        : null;
    final effectiveUnitPriceKobo = effectiveCustomKobo ?? catalogUnitPriceKobo;
    final lineTotalKobo = (effectiveUnitPriceKobo * qty).round();
    final resolved = _resolveDiscount(
      lineTotalKobo: lineTotalKobo,
      maxPercent: maxPercent,
    );

    // Option A: clamp the discount so that the effective unit price after discount
    // does not dip below floorKobo.
    final maxLineDiscountKobo = ((effectiveUnitPriceKobo - floorKobo) * qty)
        .round();
    final discountKobo = resolved.discountKobo.clamp(0, maxLineDiscountKobo);

    // Auto-snap the percent input to the role cap when exceeded (§13.2).
    if (resolved.cappedByRole && _discountKind == 'percent') {
      final capText = maxPercent.toString();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _discountCtrl.text == capText) return;
        _discountCtrl.text = capText;
        _discountCtrl.selection = TextSelection.collapsed(
          offset: capText.length,
        );
      });
    }

    final muted = t.textTheme.bodySmall?.color ?? text;
    return Container(
      key: EditItemKeys.sheet,
      decoration: salesSheetDecoration(context),
      // Scrolls so the fixed-height content never overflows when the keyboard
      // shrinks the sheet. Bottom padding is nav-only (deviceBottomPadding) —
      // MainLayout's Scaffold resize lifts the sheet above the keyboard, and the
      // scroll view lets the last field clear it.
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
            SalesSheetHeader(
              title: widget.isNew ? 'Add to Cart' : 'Edit Quantity',
              subtitle: widget.item['name'] as String?,
              leading: IconTile(
                icon: widget.isNew ? AppIcons.cartAdd : AppIcons.edit,
                size: 44,
              ),
              trailing: [
                SalesBackButton(
                  key: EditItemKeys.close,
                  icon: AppIcons.close,
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(20)),

            // Quantity: − field + (the Cart line's stepper look, 48dp).
            DecoratedBox(
              key: EditItemKeys.quantity,
              decoration: AppDecorations.card(context),
              child: Padding(
                padding: EdgeInsets.all(context.getRSize(10)),
                child: Row(
                  children: [
                    SalesStepButton(
                      key: EditItemKeys.minus,
                      icon: AppIcons.minus,
                      tooltip: 'Less',
                      onPressed: () => _updateQty(-1),
                    ),
                    SizedBox(width: context.getRSize(10)),
                    Expanded(
                      child: AppInput(
                        controller: _qtyCtrl,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
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
                    SizedBox(width: context.getRSize(10)),
                    SalesStepButton(
                      key: EditItemKeys.plus,
                      icon: AppIcons.add,
                      tooltip: 'More',
                      onPressed: () => _updateQty(1),
                    ),
                  ],
                ),
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
            // What the cart already holds — add mode only, so the field reads
            // as the new total rather than an amount to add (#317).
            if (widget.isNew && _inCartAtOpen > 0) ...[
              SizedBox(height: context.getRSize(10)),
              Text(
                '${_trimNum(_inCartAtOpen)} already in cart',
                textAlign: TextAlign.center,
                style: context.boldStyle(12).copyWith(color: primary),
              ),
            ],
            // Available-stock cap hint — only in add mode (§16).
            if (widget.isNew) ...[
              SizedBox(height: context.getRSize(10)),
              Text(
                '${_trimNum(widget.maxStock)} in stock — quantity can\'t exceed this',
                textAlign: TextAlign.center,
                style: context.semiBoldStyle(12).copyWith(color: muted),
              ),
            ],

            SizedBox(height: context.getRSize(20)),

            // ── Custom Price (§13.4) ──────────────────────────────────────────
            // Only for users granted `sales.set_custom_price`. Lets the line be
            // sold at a price other than its designated selling price.
            if (canSetCustomPrice) ...[
              _customPriceSection(
                catalogUnitPriceKobo: catalogUnitPriceKobo,
                hasCustomPrice: hasCustomPrice,
                effectiveUnitPriceKobo: effectiveUnitPriceKobo,
                floorKobo: floorKobo,
                maxPercent: maxPercent,
                customKobo: customKobo,
              ),
              SizedBox(height: context.getRSize(20)),
            ],

            // ── Apply Discount (§13.2) ────────────────────────────────────────
            _discountSection(
              canDiscount: canDiscount,
              maxPercent: maxPercent,
              lineTotalKobo: lineTotalKobo,
              discountKobo: discountKobo,
              cappedByRole: resolved.cappedByRole,
            ),

            SizedBox(height: context.getRSize(24)),

            // Action Buttons
            if (widget.isNew)
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: AppButton(
                      text: 'Cancel',
                      variant: AppButtonVariant.ghost,
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  SizedBox(width: context.getRSize(16)),
                  Expanded(
                    flex: 3,
                    child: AppButton(
                      text: 'Add to Cart',
                      variant: AppButtonVariant.primary,
                      onPressed: () {
                        final cart = ref.read(cartProvider);
                        final id = widget.newProduct!.id;
                        // Never exceed available stock (the POS card count).
                        final upper = _maxQty < 0.5 ? 0.5 : _maxQty;
                        final qtyVal = (double.tryParse(_qtyCtrl.text) ?? 1.0)
                            .clamp(0.5, upper);
                        // Set the line to this total (matches the cart editor):
                        // update if the product is already in the cart, else add.
                        final exists = cart.value.any((i) => i['id'] == id);
                        final accepted = exists
                            ? cart.updateQty(widget.item['name'], qtyVal)
                            : cart.addItem(
                                widget.newProduct!,
                                qty: qtyVal,
                                maxStock: widget.maxStock,
                                tier: widget.tier,
                              );
                        // Apply (or clear) the custom price before the discount
                        // so the discount clamps to the new line total (§13.4).
                        if (canSetCustomPrice) {
                          cart.setCustomPrice(
                            widget.item['name'],
                            customPriceKobo: hasCustomPrice ? customKobo : null,
                            maxPercent: maxPercent,
                          );
                        }
                        // Apply the resolved (role-capped) discount to the line.
                        if (discountKobo > 0) {
                          final entered = _enteredDiscount();
                          cart.setLineDiscount(
                            widget.item['name'],
                            kind: _discountKind,
                            enteredValue: entered,
                            discountKobo: discountKobo,
                            maxPercent: maxPercent,
                          );
                        }
                        Navigator.pop(context, accepted);
                      },
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: AppButton(
                      text: 'Remove',
                      variant: AppButtonVariant.danger,
                      icon: AppIcons.delete,
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
                      onPressed: () {
                        final cart = ref.read(cartProvider);
                        final qty = double.tryParse(_qtyCtrl.text) ?? 1.0;
                        cart.updateQty(widget.item['name'], qty);
                        // Apply (or clear) the custom price before the discount
                        // so the discount clamps to the new line total (§13.4).
                        if (canSetCustomPrice) {
                          cart.setCustomPrice(
                            widget.item['name'],
                            customPriceKobo: hasCustomPrice ? customKobo : null,
                            maxPercent: maxPercent,
                          );
                        }
                        // Persist the resolved (role-capped) discount alongside qty.
                        final entered = _enteredDiscount();
                        cart.setLineDiscount(
                          widget.item['name'],
                          kind: _discountKind,
                          enteredValue: entered,
                          discountKobo: discountKobo,
                          maxPercent: maxPercent,
                        );
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

  Widget _customPriceSection({
    required int catalogUnitPriceKobo,
    required bool hasCustomPrice,
    required int effectiveUnitPriceKobo,
    required int floorKobo,
    required int maxPercent,
    required int customKobo,
  }) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    final showCustomWarning = hasCustomPrice && customKobo <= floorKobo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('CUSTOM PRICE'),
        SizedBox(height: context.getRSize(4)),
        Text(
          'Designated price: ${formatCurrency(catalogUnitPriceKobo / 100.0)}',
          style: context.semiBoldStyle(12).copyWith(color: muted),
        ),
        SizedBox(height: context.getRSize(10)),
        Row(
          children: [
            Container(
              width: kMinInteractiveDimension,
              height: kMinInteractiveDimension,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  t.extension<AppSchemeColors>()?.primaryTint ??
                      primary.withValues(alpha: 0.12),
                  t.colorScheme.surface,
                ),
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
                border: Border.all(color: primary.withValues(alpha: 0.5)),
              ),
              child: Text(
                activeCurrencySymbol,
                style: context.extraBoldStyle(16).copyWith(color: primary),
              ),
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: AppInput(
                controller: _customPriceCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter(grouping: false)],
                hintText: 'Use designated price',
              ),
            ),
          ],
        ),
        if (hasCustomPrice) ...[
          SizedBox(height: context.getRSize(10)),
          Text(
            'Selling at ${formatCurrency(effectiveUnitPriceKobo / 100.0)} per '
            'unit (was ${formatCurrency(catalogUnitPriceKobo / 100.0)}).',
            style: context.boldStyle(13).copyWith(color: primary),
          ),
        ],
        if (showCustomWarning) ...[
          SizedBox(height: context.getRSize(4)),
          Text(
            'Lowest allowed price is ${formatCurrency(floorKobo / 100.0)} (max discount $maxPercent%).',
            style: context.semiBoldStyle(12).copyWith(color: f.warning),
          ),
        ],
      ],
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
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    // Cashier (or any role capped at 0%): blocked entirely (§13.2).
    if (!canDiscount) {
      return Container(
        key: EditItemKeys.discountBlocked,
        width: double.infinity,
        padding: EdgeInsets.all(context.getRSize(12)),
        decoration: BoxDecoration(
          color: f.neutralTile,
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
          border: Border.all(color: t.dividerColor),
        ),
        child: Row(
          children: [
            AppIcon(
              AppIcons.lock,
              size: context.getRSize(18),
              color: f.neutralIcon,
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: Text(
                'Discounts not allowed at your role. Ask Manager.',
                style: context.semiBoldStyle(13).copyWith(color: muted),
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
        _sectionLabel('APPLY DISCOUNT'),
        SizedBox(height: context.getRSize(10)),
        Row(
          children: [
            _kindChip('%', 'percent'),
            SizedBox(width: context.getRSize(8)),
            _kindChip(activeCurrencySymbol, 'naira'),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: AppInput(
                controller: _discountCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter(grouping: false)],
                hintText: _discountKind == 'percent'
                    ? '0%'
                    : '${activeCurrencySymbol}0',
              ),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(10)),
        if (discountKobo > 0)
          Text(
            'Saving ${formatCurrency(discountKobo / 100.0)} — '
            'new line total: ${formatCurrency(newLineTotal / 100.0)}',
            style: context.boldStyle(13).copyWith(color: f.green),
          ),
        if (cappedByRole)
          Padding(
            padding: EdgeInsets.only(top: context.getRSize(4)),
            child: Text(
              'Maximum discount is $maxPercent%. Capped.',
              style: context.semiBoldStyle(12).copyWith(color: f.warning),
            ),
          ),
      ],
    );
  }

  /// A muted uppercase group label ("CUSTOM PRICE", "APPLY DISCOUNT").
  Widget _sectionLabel(String text) {
    final t = Theme.of(context);
    return Text(
      text,
      style: context
          .boldStyle(12)
          .copyWith(
            letterSpacing: 0.5,
            color: t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface,
          ),
    );
  }

  /// The % / currency toggle: a 48dp square, selected = primary tint + border.
  Widget _kindChip(String label, String kind) {
    final t = Theme.of(context);
    final selected = _discountKind == kind;
    final primary = t.colorScheme.primary;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected
            ? Color.alphaBlend(
                t.extension<AppSchemeColors>()?.primaryTint ??
                    primary.withValues(alpha: 0.12),
                t.colorScheme.surface,
              )
            : t.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? primary : t.dividerColor,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          key: EditItemKeys.kind(kind),
          onTap: () => setState(() => _discountKind = kind),
          borderRadius: radius,
          child: SizedBox(
            width: kMinInteractiveDimension,
            height: kMinInteractiveDimension,
            child: Center(
              child: Text(
                label,
                style: context
                    .extraBoldStyle(16)
                    .copyWith(color: selected ? primary : muted),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A ±0.5 chip for fractional sales, 48dp tall.
  Widget _microAdjustChip(String label, VoidCallback onTap) {
    final t = Theme.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Material(
      color: t.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: t.dividerColor),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
            minWidth: kMinInteractiveDimension,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: context
                    .boldStyle(13)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keys the Edit Item tests find the parts by (#393).
abstract final class EditItemKeys {
  static const sheet = Key('edit-item-sheet');
  static const close = Key('edit-item-close');
  static const quantity = Key('edit-item-quantity');
  static const minus = Key('edit-item-minus');
  static const plus = Key('edit-item-plus');
  static const discountBlocked = Key('edit-item-discount-blocked');
  static Key kind(String kind) => Key('edit-item-kind-$kind');
}
