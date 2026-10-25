import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/listings/listing_content.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Keys for the listing boxes (#473), shared by the Product Details pop-up and
/// the Add / Edit Product form.
abstract final class ListingFieldKeys {
  static const description = ValueKey('listing-description');
  static const brand = ValueKey('listing-brand');
  static const minOrder = ValueKey('listing-min-order');
  static const orderStep = ValueKey('listing-order-step');
  static const maxOrder = ValueKey('listing-max-order');
}

/// The five text boxes behind a product's online listing (#473).
class ListingControllers {
  ListingControllers();

  final description = TextEditingController();
  final brand = TextEditingController();
  final minOrder = TextEditingController();
  final orderStep = TextEditingController();
  final maxOrder = TextEditingController();

  /// Fills the boxes from saved content. Default limits stay blank (blank
  /// minimum and step mean 1, blank maximum means no limit).
  void seed(ListingContent c) {
    description.text = c.onlineDescription ?? '';
    brand.text = c.brand ?? '';
    minOrder.text = c.minOrderQty == 1 ? '' : '${c.minOrderQty}';
    orderStep.text = c.orderStep == 1 ? '' : '${c.orderStep}';
    maxOrder.text = c.maxOrderQty == null ? '' : '${c.maxOrderQty}';
  }

  ListingParse parse() => parseListingContent(
    description: description.text,
    brand: brand.text,
    minOrder: minOrder.text,
    orderStep: orderStep.text,
    maxOrder: maxOrder.text,
  );

  void dispose() {
    description.dispose();
    brand.dispose();
    minOrder.dispose();
    orderStep.dispose();
    maxOrder.dispose();
  }
}

/// One line describing the order limits, e.g. "At least 6 · In steps of 12 ·
/// Up to 48". "Any amount" when the product has no limits.
String orderLimitsSummary(OrderQuantityRule rule) {
  if (rule.isDefault) return 'Any amount';
  return [
    if (rule.min > 1) 'At least ${rule.min}',
    if (rule.step > 1) 'In steps of ${rule.step}',
    if (rule.max != null) 'Up to ${rule.max}',
  ].join(' · ');
}

/// The listing boxes, stacked. No LayoutBuilder: the pop-up lays this out
/// inside AlertDialog's intrinsic-width pass, which LayoutBuilder cannot join.
class ListingContentFields extends StatelessWidget {
  const ListingContentFields({
    super.key,
    required this.controllers,
    this.autofocus = false,
    this.fieldKeys = const {},
  });

  final ListingControllers controllers;
  final bool autofocus;

  /// Optional extra keys (e.g. for scroll-to-error) per box.
  final Map<ListingField, GlobalKey> fieldKeys;

  @override
  Widget build(BuildContext context) {
    final gap = context.getRSize(AppSpacing.m);
    Widget qty(
      ListingField f,
      Key key,
      TextEditingController c,
      String label,
      String hint,
    ) {
      return KeyedSubtree(
        key: fieldKeys[f],
        child: AppInput(
          key: key,
          controller: c,
          labelText: label,
          hintText: hint,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
        ),
      );
    }

    final quantities = [
      qty(
        ListingField.minOrder,
        ListingFieldKeys.minOrder,
        controllers.minOrder,
        'Smallest order',
        '1',
      ),
      qty(
        ListingField.orderStep,
        ListingFieldKeys.orderStep,
        controllers.orderStep,
        'Order in steps of',
        '1',
      ),
      qty(
        ListingField.maxOrder,
        ListingFieldKeys.maxOrder,
        controllers.maxOrder,
        'Largest order',
        'No limit',
      ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeyedSubtree(
          key: fieldKeys[ListingField.description],
          child: AppInput(
            key: ListingFieldKeys.description,
            controller: controllers.description,
            labelText: 'Online description',
            hintText: 'What should shoppers know about it?',
            autofocus: autofocus,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            minLines: 3,
            maxLines: 6,
            inputFormatters: [
              LengthLimitingTextInputFormatter(kOnlineDescriptionMaxLength),
            ],
          ),
        ),
        SizedBox(height: gap),
        KeyedSubtree(
          key: fieldKeys[ListingField.brand],
          child: AppInput(
            key: ListingFieldKeys.brand,
            controller: controllers.brand,
            labelText: 'Brand',
            hintText: 'e.g. Nestlé',
            textCapitalization: TextCapitalization.words,
            inputFormatters: [
              LengthLimitingTextInputFormatter(kBrandMaxLength),
            ],
          ),
        ),
        for (final q in quantities) ...[SizedBox(height: gap), q],
      ],
    );
  }
}
