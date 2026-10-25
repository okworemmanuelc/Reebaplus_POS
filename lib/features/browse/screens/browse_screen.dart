import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/data/area_selection.dart';
import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_account_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/storefront_store_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/browse_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_cart_button.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/area_picker.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/smooth_route.dart';

/// Browse — the app's front door for a phone with no business user (#425,
/// PRD #421 decisions 2026-10-21). One ranked feed of products from every
/// online shop that delivers to the Shopper's area, cross-store search, a
/// Reebaplus category filter, and store pages. No account needed.
///
/// Online only: every read goes through the storefront RPCs
/// ([storefrontServiceProvider]); offline shows "Connect to the internet to
/// browse". **Sell on Reebaplus** pushes today's [WelcomeScreen] unchanged
/// and stays tappable offline. The cart and account buttons open the
/// Shopper's cart and orders (#426).
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  static const _searchDelay = Duration(milliseconds: 400);

  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String? _category;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDelay, () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  void _openWelcome() {
    Navigator.of(context).push(SmoothRoute(page: const WelcomeScreen()));
  }

  Future<void> _pickArea(ShopperArea? current) async {
    final picked = await showAreaPicker(
      context,
      allowWholeState: true,
      initialValue: current == null || current.state == null
          ? null
          : AreaSelection(
              country: current.country,
              state: current.state!,
              lga: current.lga,
            ),
    );
    if (picked == null || !mounted) return;
    await ref
        .read(shopperAreaProvider.notifier)
        .choose(ShopperArea.fromSelection(picked));
  }

  void _openStore(StorefrontCard card) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StorefrontStoreScreen(storeId: card.storeId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final areaAsync = ref.watch(shopperAreaProvider);
    final area = areaAsync.valueOrNull;
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: BrowseTopBar(
          height: BrowseTopBar.heightFor(context),
          header: ScreenHeader(
            icon: AppIcons.storefront,
            title: 'Browse',
            subtitle: area?.label,
            actions: [
              ShopperBarButton(
                key: const Key('browse-account'),
                icon: AppIcons.user,
                tooltip: 'Your account and orders',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ShopperAccountScreen(),
                  ),
                ),
              ),
              const ShopperCartButton(),
              SellOnReebaplusButton(onPressed: _openWelcome),
            ],
          ),
        ),
        body: switch (areaAsync) {
          AsyncData(value: null) => _AreaPrompt(
            onPick: () => _pickArea(null),
            onAllNigeria: () => ref
                .read(shopperAreaProvider.notifier)
                .choose(const ShopperArea.allNigeria()),
          ),
          AsyncData(value: final ShopperArea chosen) => _BrowseBody(
            area: chosen,
            query: _query,
            category: _category,
            search: _search,
            onSearchChanged: _onSearchChanged,
            onCategory: (slug) => setState(() => _category = slug),
            onChangeArea: () => _pickArea(chosen),
            onOpenStore: _openStore,
          ),
          _ => const SizedBox.shrink(),
        },
      ),
    );
  }
}

/// First Browse: where should products come from?
class _AreaPrompt extends StatelessWidget {
  const _AreaPrompt({required this.onPick, required this.onAllNigeria});

  final VoidCallback onPick;
  final VoidCallback onAllNigeria;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const Key('browse-area-prompt'),
    padding: EdgeInsets.only(bottom: context.deviceBottomPadding),
    child: BrowseMessage(
      icon: AppIcons.location,
      title: 'Where should we deliver?',
      text: 'Pick your area to see products from shops that deliver to you.',
      actionLabel: 'Choose my area',
      onAction: onPick,
      secondaryLabel: 'Browse all of Nigeria',
      onSecondary: onAllNigeria,
    ),
  );
}

/// Area row, search, category bar and the card list (feed or search).
class _BrowseBody extends ConsumerWidget {
  const _BrowseBody({
    required this.area,
    required this.query,
    required this.category,
    required this.search,
    required this.onSearchChanged,
    required this.onCategory,
    required this.onChangeArea,
    required this.onOpenStore,
  });

  final ShopperArea area;
  final String query;
  final String? category;
  final TextEditingController search;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String?> onCategory;
  final VoidCallback onChangeArea;
  final void Function(StorefrontCard card) onOpenStore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listQuery = query.isEmpty
        ? StorefrontQuery.feed(area: area, category: category)
        : StorefrontQuery.search(area: area, query: query, category: category);
    final list = ref.watch(storefrontListProvider(listQuery));
    final notifier = ref.read(storefrontListProvider(listQuery).notifier);

    final header = SliverLayoutBuilder(
      builder: (context, c) {
        final gutter = browseGutter(context, c.crossAxisExtent);
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            context.getRSize(8),
            gutter,
            context.getRSize(12),
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BrowseAreaRow(label: area.label, onChange: onChangeArea),
                SizedBox(height: context.getRSize(4)),
                AppInput(
                  key: const Key('browse-search'),
                  controller: search,
                  hintText: 'Search products in all shops',
                  prefixIcon: const AppIcon(AppIcons.search),
                  textInputAction: TextInputAction.search,
                  onChanged: onSearchChanged,
                  onFieldSubmitted: onSearchChanged,
                ),
                SizedBox(height: context.getRSize(10)),
                BrowseCategoryBar(selected: category, onSelected: onCategory),
              ],
            ),
          ),
        );
      },
    );

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 600) unawaited(notifier.loadMore());
        return false;
      },
      child: CustomScrollView(
        key: const Key('browse-scroll'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          header,
          ...browseListSlivers(
            context,
            state: list,
            onRetry: notifier.retry,
            onOpenStore: onOpenStore,
            empty: query.isEmpty
                ? BrowseMessage(
                    icon: AppIcons.storefront,
                    title: 'No shops deliver here yet',
                    text: category == null
                        ? 'Try another area, or browse all of Nigeria.'
                        : 'Nothing in this category yet. Try another one.',
                    actionLabel: 'Change area',
                    onAction: onChangeArea,
                  )
                : BrowseMessage(
                    icon: AppIcons.search,
                    title: 'No products match "$query"',
                    text: 'Check the spelling or try a shorter name.',
                  ),
          ),
        ],
      ),
    );
  }
}

