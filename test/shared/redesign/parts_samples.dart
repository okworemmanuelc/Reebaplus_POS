// Sample data for the shared parts (#352 PR 2), in the mockups' sample data
// (Stallion Global / Abuja HQ / Emmanuel Okwor). Used by the widget tests and
// the gallery goldens so both exercise the same examples.

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

void _noop() {}

/// One gallery per part: name → builder of its examples.
final Map<String, List<Widget> Function(BuildContext)> partGalleries = {
  'screen_header': (context) => [
    const ScreenHeader(
      icon: AppIcons.pos,
      title: 'Point of Sale',
      subtitle: 'Abuja HQ',
      leading: IconButton(
        onPressed: _noop,
        constraints: BoxConstraints(
          minWidth: kMinInteractiveDimension,
          minHeight: kMinInteractiveDimension,
        ),
        icon: AppIcon(AppIcons.menu),
      ),
      actions: [HeaderBell(count: 8, onPressed: _noop)],
    ),
    const ScreenHeader(
      icon: AppIcons.settings,
      title: 'CEO Settings with a very long title that must end in dots',
      subtitle: 'Abuja HQ',
      actions: [HeaderBell(count: 0, onPressed: _noop)],
    ),
  ],
  'stat_card': (context) => const [
    StatCard(
      icon: AppIcons.profit,
      tone: IconTileTone.green,
      title: 'Net Profit',
      value: '₦7,100',
      subtitle: 'Revenue minus cost of goods & expenses',
      pillLabel: 'Positive',
      pillTone: TagPillTone.green,
    ),
    StatCard(
      icon: AppIcons.time,
      tone: IconTileTone.warning,
      title: 'Pending Orders',
      value: '0',
      subtitle: 'Orders awaiting fulfillment',
      pillLabel: 'Clear',
    ),
    StatCard(
      icon: AppIcons.expenses,
      tone: IconTileTone.danger,
      title: 'Total Expenses',
      value: '₦0',
      subtitle: 'Including operations & staff',
      pillLabel: 'None',
      pillTone: TagPillTone.danger,
    ),
  ],
  'tag_pill': (context) => [
    Wrap(
      spacing: context.getRSize(8),
      runSpacing: context.getRSize(8),
      children: const [
        TagPill(label: 'PRO', tone: TagPillTone.solidInfo),
        TagPill(label: 'CEO'),
        TagPill(label: 'Pending', tone: TagPillTone.warning),
        TagPill(label: 'Debt', tone: TagPillTone.danger),
        TagPill(label: 'Live', tone: TagPillTone.neutral),
        StatusPill(label: 'Positive', tone: TagPillTone.green),
        StatusPill(label: 'None', tone: TagPillTone.danger),
        StatusPill(label: 'Active', tone: TagPillTone.neutral),
      ],
    ),
  ],
  'product_tile': (context) => [
    SizedBox(
      height: context.getRSize(250),
      child: Row(
        children: [
          const Expanded(
            child: ProductTile(
              name: 'Star Lager',
              subtitle: '60cl · Crate of 12',
              priceLabel: '₦9,600',
              stockLabel: '38',
              categoryName: 'Beer',
              inCartQty: 2,
              onTap: _noop,
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          const Expanded(
            child: ProductTile(
              name: 'Guinness Foreign Extra',
              subtitle: '60cl · Crate of 12',
              priceLabel: '₦12,000',
              stockLabel: '4',
              stockLevel: StockLevel.low,
              categoryName: 'Stout',
              onTap: _noop,
            ),
          ),
        ],
      ),
    ),
    SizedBox(
      height: context.getRSize(250),
      child: Row(
        children: [
          const Expanded(
            child: ProductTile(
              name: 'Eva Water',
              subtitle: '75cl · Pack of 12',
              priceLabel: '₦2,700',
              stockLabel: '60',
              categoryName: 'Water',
              onTap: _noop,
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          const Expanded(
            child: ProductTile(
              name: 'Power Horse',
              subtitle: '25cl · Pack of 24',
              priceLabel: '₦16,800',
              stockLabel: '0',
              stockLevel: StockLevel.out,
              categoryName: 'Energy',
              onTap: _noop,
            ),
          ),
        ],
      ),
    ),
  ],
  'category_chip': (context) => [
    Wrap(
      spacing: context.getRSize(6),
      children: [
        const CategoryChip(label: 'All', selected: true, onTap: _noop),
        for (final c in const [
          'Beer',
          'Stout',
          'Soft Drinks',
          'Water',
          'Malt',
          'Energy',
          'Biscuits',
        ])
          CategoryChip(
            label: c,
            categoryName: c,
            selected: false,
            onTap: _noop,
          ),
      ],
    ),
  ],
  'cart_line': (context) => [
    const CartLine(
      name: 'Star Lager',
      icon: AppIcons.beerMug,
      quantityLabel: '2',
      unitPriceLabel: '₦9,600',
      totalLabel: '₦19,200',
      detail: '60cl · Crate of 12',
      isLastUnit: false,
      onIncrement: _noop,
      onDecrement: _noop,
    ),
    const CartLine(
      name: 'Hero Lager',
      icon: AppIcons.beerMug,
      quantityLabel: '1',
      unitPriceLabel: '₦8,400',
      totalLabel: '₦8,400',
      detail: '60cl · Crate of 12',
      isLastUnit: true,
      onIncrement: _noop,
      onDecrement: _noop,
    ),
  ],
  'view_cart_bar': (context) => [
    const ViewCartBar(
      itemCount: 5,
      customerName: 'Walk-in Customer',
      total: 33500,
      onTap: _noop,
    ),
  ],
  'settings_row': (context) => [
    const SettingsRow(
      icon: AppIcons.business,
      tone: IconTileTone.info,
      title: 'Business Info',
      subtitle: 'Name, type, and currency',
      onTap: _noop,
    ),
    const SettingsRow(
      icon: AppIcons.store,
      tone: IconTileTone.green,
      title: 'Stores',
      subtitle: 'Your store locations',
      onTap: _noop,
    ),
    const SettingsRow(
      icon: AppIcons.lock,
      tone: IconTileTone.danger,
      title: 'Security',
      subtitle: 'Auto-lock and biometric login',
      onTap: _noop,
    ),
  ],
  'profile_card': (context) => [
    const ProfileCard(
      title: 'Stallion Global',
      subtitle: 'Emmanuel Okwor',
      tags: [
        (label: 'PRO', tone: TagPillTone.solidInfo),
        (label: 'CEO', tone: TagPillTone.info),
      ],
      onTap: _noop,
    ),
  ],
  'section_header': (context) => const [
    SectionHeader(
      title: 'Performance Overview',
      subtitle: 'Analytics for the selected period',
    ),
    SectionHeader(title: 'Business'),
  ],
};
