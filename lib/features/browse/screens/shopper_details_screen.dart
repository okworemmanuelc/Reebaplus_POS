import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/data/area_selection.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/shopper_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_texts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/area_picker.dart';

/// The Shopper's details (#426): name, phone and delivery address (state,
/// LGA, street). Asked the first time they place an order; saved as their
/// defaults; editable later. Pops the saved [ShopperProfile].
class ShopperDetailsScreen extends ConsumerStatefulWidget {
  const ShopperDetailsScreen({super.key, this.initial});

  /// Prefill when editing.
  final ShopperProfile? initial;

  @override
  ConsumerState<ShopperDetailsScreen> createState() =>
      _ShopperDetailsScreenState();
}

class _ShopperDetailsScreenState extends ConsumerState<ShopperDetailsScreen> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _phone = TextEditingController(
    text: widget.initial?.defaultPhone?.phone ?? '',
  );
  late final _street = TextEditingController(
    text: widget.initial?.defaultAddress?.street ?? '',
  );
  late AreaSelection? _area = _initialArea();
  String? _error;
  bool _busy = false;

  AreaSelection? _initialArea() {
    final a = widget.initial?.defaultAddress;
    if (a == null) return null;
    return AreaSelection(country: a.country, state: a.state, lga: a.lga);
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _street.dispose();
    super.dispose();
  }

  Future<void> _pickArea() async {
    final picked = await showAreaPicker(context, initialValue: _area);
    if (picked != null && mounted) setState(() => _area = picked);
  }

  Future<void> _save() async {
    final area = _area;
    final problem = _name.text.trim().isEmpty
        ? 'Type your name'
        : _phone.text.trim().length < 7
        ? 'Type a phone number the shop can call'
        : area == null || area.lga == null
        ? 'Choose your state and local government area'
        : _street.text.trim().isEmpty
        ? 'Type your street address'
        : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profile = await ref
          .read(shopperServiceProvider)
          .saveProfile(
            name: _name.text,
            phone: _phone.text,
            address: ShopperAddress(
              country: area!.country,
              state: area.state,
              lga: area.lga!,
              street: _street.text.trim(),
            ),
          );
      ref.invalidate(shopperProfileProvider);
      if (mounted) Navigator.of(context).pop(profile);
    } on ShopperException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = shopperFailureText(e.failure);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final area = _area;
    return ShopperPage(
      icon: AppIcons.user,
      title: widget.initial == null ? 'Your details' : 'Edit your details',
      bottom: AppButton(
        key: const Key('shopper-details-save'),
        text: 'Save details',
        isLoading: _busy,
        onPressed: _busy ? null : _save,
      ),
      body: SingleChildScrollView(
        key: const Key('shopper-details-scroll'),
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShopperSection(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppInput(
                    key: const Key('shopper-name'),
                    controller: _name,
                    labelText: 'Your name',
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                  ),
                  SizedBox(height: context.getRSize(12)),
                  AppInput(
                    key: const Key('shopper-phone'),
                    controller: _phone,
                    labelText: 'Phone',
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                  ),
                  SizedBox(height: context.getRSize(12)),
                  AppButton(
                    key: const Key('shopper-area'),
                    text: area == null
                        ? 'Choose state and local government area'
                        : '${area.lga ?? 'All'}, ${area.state}',
                    icon: AppIcons.location,
                    variant: AppButtonVariant.outline,
                    onPressed: _pickArea,
                  ),
                  SizedBox(height: context.getRSize(12)),
                  AppInput(
                    key: const Key('shopper-street'),
                    controller: _street,
                    labelText: 'Street address',
                    hintText: 'House number, street, landmark',
                    textCapitalization: TextCapitalization.sentences,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            Text(
              kShopperSharingNotice,
              key: const Key('shopper-sharing-notice'),
              style: context.regularStyle(13).copyWith(color: muted),
            ),
            if (_error != null) ...[
              SizedBox(height: context.getRSize(10)),
              Text(
                _error!,
                key: const Key('shopper-details-error'),
                style: context
                    .semiBoldStyle(13)
                    .copyWith(color: t.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
