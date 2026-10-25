import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/data/area_selection.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/shopper_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/core/storefront/storefront_providers.dart';
import 'package:reebaplus_pos/core/storefront/storefront_service.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/screens/my_orders_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_texts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/area_picker.dart';

/// Where a shop stands for the chosen address.
enum _Delivery { checking, delivers, doesNotDeliver, unknown }

/// Place order (#426): choose the address and phone (default or another),
/// add a note, then one Online Order goes to each shop. Shops that don't
/// deliver to the chosen address are flagged before placing and their items
/// stay in the cart. Each shop is placed independently: a shop that fails a
/// check is reported and its lines stay in the cart; the others are placed.
class PlaceOrderScreen extends ConsumerStatefulWidget {
  const PlaceOrderScreen({super.key, required this.profile});

  final ShopperProfile profile;

  @override
  ConsumerState<PlaceOrderScreen> createState() => _PlaceOrderScreenState();
}

class _PlaceOrderScreenState extends ConsumerState<PlaceOrderScreen> {
  late final List<ShopperAddress> _addresses = [...widget.profile.addresses];
  late final List<String> _phones = [
    for (final p in widget.profile.phones) p.phone,
  ];
  late ShopperAddress? _address = widget.profile.defaultAddress;
  late String? _phone = widget.profile.defaultPhone?.phone;
  final _note = TextEditingController();

  /// One client-generated id per shop, kept for this screen's life so a retry
  /// after a dropped connection never places a shop's order twice.
  final Map<String, String> _orderIds = {};
  final Map<String, _Delivery> _delivery = {};
  bool _busy = false;
  String? _error;
  List<PlaceOrderResult>? _results;

  /// Names of the lines as placed, for the result messages.
  final Map<String, String> _productNames = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkDelivery());
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  List<ShopperCartGroup> get _groups =>
      (ref.read(shopperCartProvider).valueOrNull ?? const ShopperCart()).groups;

  Future<void> _checkDelivery() async {
    await ref.read(shopperCartProvider.future);
    final address = _address;
    if (address == null || !mounted) return;
    final groups = _groups;
    setState(() {
      for (final g in groups) {
        _delivery[g.storeId] = _Delivery.checking;
      }
    });
    final service = ref.read(storefrontServiceProvider);
    await Future.wait([
      for (final g in groups)
        () async {
          _Delivery result;
          try {
            final store = await service.store(
              storeId: g.storeId,
              area: address.area,
            );
            result = store == null
                ? _Delivery.doesNotDeliver
                : store.deliversToArea
                ? _Delivery.delivers
                : _Delivery.doesNotDeliver;
          } on StorefrontException {
            // Unknown (offline / server): let Place order's own check decide.
            result = _Delivery.unknown;
          }
          if (mounted && _address == address) {
            setState(() => _delivery[g.storeId] = result);
          }
        }(),
    ]);
  }

  Future<void> _chooseAnotherAddress() async {
    final picked = await showDialog<ShopperAddress>(
      context: context,
      builder: (_) => const _NewAddressDialog(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (!_addresses.contains(picked)) _addresses.add(picked);
      _address = picked;
    });
    unawaited(_rememberAddress(picked));
    await _checkDelivery();
  }

  Future<void> _rememberAddress(ShopperAddress address) async {
    try {
      await ref.read(shopperServiceProvider).saveAddress(address);
    } on ShopperException {
      // Saving for next time is a convenience; this order still uses it.
    }
  }

  Future<void> _chooseAnotherPhone() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => const _NewPhoneDialog(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (!_phones.contains(picked)) _phones.add(picked);
      _phone = picked;
    });
    try {
      await ref.read(shopperServiceProvider).savePhone(picked);
    } on ShopperException {
      // A convenience only.
    }
  }

  Future<void> _place() async {
    final address = _address;
    final phone = _phone;
    if (address == null || phone == null) {
      setState(() => _error = 'Choose an address and a phone');
      return;
    }
    final groups = [
      for (final g in _groups)
        if (_delivery[g.storeId] != _Delivery.doesNotDeliver) g,
    ];
    if (groups.isEmpty) return;
    for (final g in groups) {
      _orderIds.putIfAbsent(g.storeId, UuidV7.generate);
      for (final l in g.lines) {
        _productNames[l.productId] = l.name;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await ref
          .read(shopperServiceProvider)
          .placeOrders(
            groups: groups,
            orderIds: _orderIds,
            phone: phone,
            address: address,
            note: _note.text,
          );
      await ref.read(shopperCartProvider.notifier).removeStores({
        for (final r in results)
          if (r.isPlaced) r.storeId,
      });
      ref.invalidate(shopperOrdersProvider);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _results = results;
      });
    } on ShopperException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = shopperFailureText(e.failure);
      });
    }
  }

  void _openMyOrders() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MyOrdersScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    if (results != null) {
      return _ResultsView(
        results: results,
        groupNames: {
          for (final g
              in ref.watch(shopperCartProvider).valueOrNull?.groups ??
                  const <ShopperCartGroup>[])
            g.storeId: g.sellerLabel,
        },
        productNames: _productNames,
        onMyOrders: _openMyOrders,
      );
    }
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final groups =
        (ref.watch(shopperCartProvider).valueOrNull ?? const ShopperCart())
            .groups;
    final placeable = [
      for (final g in groups)
        if (_delivery[g.storeId] != _Delivery.doesNotDeliver) g,
    ];
    final checking = _delivery.values.contains(_Delivery.checking);
    return ShopperPage(
      icon: AppIcons.cartCheckout,
      title: 'Place order',
      bottom: AppButton(
        key: const Key('shopper-place-orders'),
        text: placeable.length <= 1
            ? 'Place order'
            : 'Place ${placeable.length} orders',
        isLoading: _busy,
        onPressed: _busy || checking || placeable.isEmpty ? null : _place,
      ),
      body: ListView(
        key: const Key('shopper-place-order-list'),
        padding: EdgeInsets.all(context.getRSize(16)),
        children: [
          ShopperSection(
            title: 'Deliver to',
            child: RadioGroup<ShopperAddress>(
              groupValue: _address,
              onChanged: (v) {
                setState(() => _address = v);
                _checkDelivery();
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final a in _addresses)
                    RadioListTile<ShopperAddress>(
                      contentPadding: EdgeInsets.zero,
                      value: a,
                      title: Text(a.label, style: context.regularStyle(14)),
                    ),
                  AppButton(
                    key: const Key('shopper-another-address'),
                    text: 'Use another address',
                    icon: AppIcons.add,
                    variant: AppButtonVariant.ghost,
                    isFullWidth: false,
                    onPressed: _chooseAnotherAddress,
                  ),
                ],
              ),
            ),
          ),
          ShopperSection(
            title: 'Phone',
            child: RadioGroup<String>(
              groupValue: _phone,
              onChanged: (v) => setState(() => _phone = v),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in _phones)
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: p,
                      title: Text(p, style: context.regularStyle(14)),
                    ),
                  AppButton(
                    key: const Key('shopper-another-phone'),
                    text: 'Use another phone',
                    icon: AppIcons.add,
                    variant: AppButtonVariant.ghost,
                    isFullWidth: false,
                    onPressed: _chooseAnotherPhone,
                  ),
                ],
              ),
            ),
          ),
          ShopperSection(
            title: 'Note for the shop (optional)',
            child: AppInput(
              key: const Key('shopper-note'),
              controller: _note,
              hintText: 'Directions, landmark, best time to call',
              maxLines: 3,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: [LengthLimitingTextInputFormatter(500)],
            ),
          ),
          for (final g in groups)
            _OrderGroupSummary(group: g, delivery: _delivery[g.storeId]),
          Text(
            '$kShopperSharingNotice Pay the shop on delivery.',
            style: context.regularStyle(12).copyWith(color: muted),
          ),
          if (_error != null) ...[
            SizedBox(height: context.getRSize(8)),
            Text(
              _error!,
              key: const Key('shopper-place-error'),
              style: context
                  .semiBoldStyle(13)
                  .copyWith(color: t.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _OrderGroupSummary extends StatelessWidget {
  const _OrderGroupSummary({required this.group, required this.delivery});

  final ShopperCartGroup group;
  final _Delivery? delivery;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final flagged = delivery == _Delivery.doesNotDeliver;
    return ShopperSection(
      key: ValueKey('shopper-order-group-${group.storeId}'),
      title: group.sellerLabel,
      child: Opacity(
        opacity: flagged ? 0.7 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (flagged)
              Container(
                key: ValueKey('shopper-out-of-area-${group.storeId}'),
                margin: EdgeInsets.only(bottom: context.getRSize(8)),
                padding: EdgeInsets.all(context.getRSize(10)),
                decoration: BoxDecoration(
                  color: f.warningTint,
                  borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
                ),
                child: Text(
                  "This shop doesn't deliver to this address. These items "
                  'stay in your cart.',
                  style: context
                      .semiBoldStyle(13)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
            for (final l in group.lines)
              Padding(
                padding: EdgeInsets.only(bottom: context.getRSize(4)),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${l.quantity} × ${l.name}',
                        style: context
                            .regularStyle(14)
                            .copyWith(color: t.colorScheme.onSurface),
                      ),
                    ),
                    Text(
                      formatCurrencyIn(l.lineTotalKobo / 100, l.currency),
                      style: context.regularStyle(14).copyWith(color: muted),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Estimated total',
                    style: context
                        .semiBoldStyle(14)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                ),
                Text(
                  formatCurrencyIn(group.subtotalKobo / 100, group.currency),
                  style: context
                      .boldStyle(15)
                      .copyWith(color: t.colorScheme.primary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What happened per shop after Place order.
class _ResultsView extends StatelessWidget {
  const _ResultsView({
    required this.results,
    required this.groupNames,
    required this.productNames,
    required this.onMyOrders,
  });

  final List<PlaceOrderResult> results;

  /// Seller labels of the shops still in the cart (the failed ones).
  final Map<String, String> groupNames;
  final Map<String, String> productNames;
  final VoidCallback onMyOrders;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final placed = results.where((r) => r.isPlaced).length;
    final failed = results.length - placed;
    return ShopperPage(
      icon: AppIcons.checkCircle,
      title: placed == 0 ? 'Not placed' : 'Order placed',
      bottom: AppButton(
        key: const Key('shopper-see-my-orders'),
        text: 'See my orders',
        icon: AppIcons.orders,
        onPressed: onMyOrders,
      ),
      body: ListView(
        key: const Key('shopper-results'),
        padding: EdgeInsets.all(context.getRSize(16)),
        children: [
          if (failed > 0)
            Padding(
              padding: EdgeInsets.only(bottom: context.getRSize(10)),
              child: Text(
                placed == 0
                    ? "We couldn't place your order. Your items are still in "
                          'your cart.'
                    : "Some shops couldn't take your order. Their items are "
                          'still in your cart.',
                style: context
                    .semiBoldStyle(14)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
            ),
          for (final r in results)
            ShopperSection(
              key: ValueKey('shopper-result-${r.storeId}'),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIcon(
                    r.isPlaced ? AppIcons.checkCircle : AppIcons.warning,
                    color: r.isPlaced ? f.greenDot : f.warning,
                    size: context.getRSize(22),
                  ),
                  SizedBox(width: context.getRSize(10)),
                  Expanded(
                    child: r.isPlaced
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Reference ${r.reference}',
                                style: context
                                    .boldStyle(15)
                                    .copyWith(color: t.colorScheme.onSurface),
                              ),
                              Text(
                                'Estimated total '
                                '${formatCurrencyIn(r.totalKobo! / 100, r.currency!)}'
                                ' · pay on delivery',
                                style: context.regularStyle(13),
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (groupNames[r.storeId] != null)
                                Text(
                                  groupNames[r.storeId]!,
                                  style: context
                                      .boldStyle(15)
                                      .copyWith(color: t.colorScheme.onSurface),
                                ),
                              Text(
                                placeOrderFailureText(
                                  r.failure!,
                                  productName: productNames[r.productId],
                                ),
                                style: context.regularStyle(13),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// "Use another address": state + LGA from the lists, then the street.
class _NewAddressDialog extends StatefulWidget {
  const _NewAddressDialog();

  @override
  State<_NewAddressDialog> createState() => _NewAddressDialogState();
}

class _NewAddressDialogState extends State<_NewAddressDialog> {
  final _street = TextEditingController();
  AreaSelection? _area;
  String? _error;

  @override
  void dispose() {
    _street.dispose();
    super.dispose();
  }

  void _done() {
    final area = _area;
    if (area == null || area.lga == null) {
      setState(() => _error = 'Choose the state and local government area');
      return;
    }
    if (_street.text.trim().isEmpty) {
      setState(() => _error = 'Type the street address');
      return;
    }
    Navigator.of(context).pop(
      ShopperAddress(
        country: area.country,
        state: area.state,
        lga: area.lga!,
        street: _street.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final area = _area;
    return AlertDialog(
      scrollable: true,
      title: const Text('Another address'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppButton(
            key: const Key('shopper-new-address-area'),
            text: area == null
                ? 'Choose state and local government area'
                : '${area.lga}, ${area.state}',
            icon: AppIcons.location,
            variant: AppButtonVariant.outline,
            onPressed: () async {
              final picked = await showAreaPicker(context, initialValue: _area);
              if (picked != null && mounted) setState(() => _area = picked);
            },
          ),
          SizedBox(height: context.getRSize(10)),
          AppInput(
            key: const Key('shopper-new-address-street'),
            controller: _street,
            labelText: 'Street address',
            textCapitalization: TextCapitalization.sentences,
          ),
          if (_error != null) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              _error!,
              style: context
                  .semiBoldStyle(13)
                  .copyWith(color: Theme.of(context).colorScheme.error),
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
        AppButton(text: 'Use it', isFullWidth: false, onPressed: _done),
      ],
    );
  }
}

/// "Use another phone".
class _NewPhoneDialog extends StatefulWidget {
  const _NewPhoneDialog();

  @override
  State<_NewPhoneDialog> createState() => _NewPhoneDialogState();
}

class _NewPhoneDialogState extends State<_NewPhoneDialog> {
  final _phone = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  void _done() {
    final phone = _phone.text.trim();
    if (phone.length < 7) {
      setState(() => _error = 'Type a phone number the shop can call');
      return;
    }
    Navigator.of(context).pop(phone);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Another phone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppInput(
            key: const Key('shopper-new-phone'),
            controller: _phone,
            labelText: 'Phone',
            autofocus: true,
            keyboardType: TextInputType.phone,
            inputFormatters: [LengthLimitingTextInputFormatter(30)],
            onFieldSubmitted: (_) => _done(),
          ),
          if (_error != null) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              _error!,
              style: context
                  .semiBoldStyle(13)
                  .copyWith(color: Theme.of(context).colorScheme.error),
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
        AppButton(text: 'Use it', isFullWidth: false, onPressed: _done),
      ],
    );
  }
}
