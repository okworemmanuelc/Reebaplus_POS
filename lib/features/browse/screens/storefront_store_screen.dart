import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_providers.dart';
import 'package:reebaplus_pos/core/storefront/storefront_service.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/widgets/browse_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_cart_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// One store's page (#425): "Business · LGA", its note, its whole online
/// catalogue (out-of-stock items greyed) with its own search and category
/// filter. A store outside the Shopper's area still opens, with "This store
/// doesn't deliver to your area" (ordering arrives in #426).
class StorefrontStoreScreen extends ConsumerStatefulWidget {
  const StorefrontStoreScreen({super.key, required this.storeId});

  final String storeId;

  @override
  ConsumerState<StorefrontStoreScreen> createState() =>
      _StorefrontStoreScreenState();
}

class _StorefrontStoreScreenState extends ConsumerState<StorefrontStoreScreen> {
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

  @override
  Widget build(BuildContext context) {
    final area =
        ref.watch(shopperAreaProvider).valueOrNull ??
        const ShopperArea.allNigeria();
    final storeAsync = ref.watch(
      storefrontStoreProvider((storeId: widget.storeId, area: area)),
    );
    final store = storeAsync.valueOrNull;
    final listQuery = StorefrontQuery.store(
      storeId: widget.storeId,
      query: _query.isEmpty ? null : _query,
      category: _category,
    );
    final list = ref.watch(storefrontListProvider(listQuery));
    final notifier = ref.read(storefrontListProvider(listQuery).notifier);

    final Widget body;
    if (storeAsync.isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (storeAsync.hasError) {
      final error = storeAsync.error;
      final offline = error is StorefrontException &&
          error.failure == StorefrontFailure.offline;
      body = BrowseMessage(
        key: Key(offline ? 'store-offline' : 'store-failed'),
        icon: offline ? AppIcons.cloudOff : AppIcons.warning,
        tone: IconTileTone.warning,
        title: offline
            ? 'Connect to the internet to browse'
            : "Couldn't load this store",
        actionLabel: 'Try again',
        onAction: () => ref.invalidate(storefrontStoreProvider),
      );
    } else if (store == null) {
      body = BrowseMessage(
        key: const Key('store-not-listed'),
        icon: AppIcons.store,
        title: "This store isn't taking online orders",
        text: 'It may be closed for online orders right now.',
        actionLabel: 'Back to Browse',
        onAction: () => Navigator.maybePop(context),
      );
    } else {
      body = NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 600) unawaited(notifier.loadMore());
          return false;
        },
        child: CustomScrollView(
          key: const Key('store-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverLayoutBuilder(
              builder: (context, c) {
                final gutter = browseGutter(context, c.crossAxisExtent);
                return SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    context.getRSize(12),
                    gutter,
                    context.getRSize(12),
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _StoreNotices(store: store),
                        AppInput(
                          key: const Key('store-search'),
                          controller: _search,
                          hintText: 'Search this store',
                          prefixIcon: const AppIcon(AppIcons.search),
                          textInputAction: TextInputAction.search,
                          onChanged: _onSearchChanged,
                          onFieldSubmitted: _onSearchChanged,
                        ),
                        SizedBox(height: context.getRSize(10)),
                        BrowseCategoryBar(
                          selected: _category,
                          onSelected: (slug) => setState(() => _category = slug),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            ...browseListSlivers(
              context,
              state: list,
              onRetry: notifier.retry,
              empty: BrowseMessage(
                icon: AppIcons.search,
                title: _query.isEmpty
                    ? 'No products here yet'
                    : 'No products match "$_query"',
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: BrowseTopBar(
          height: BrowseTopBar.heightFor(context),
          header: ScreenHeader(
            leading: BrowseBackButton(onPressed: () => Navigator.maybePop(context)),
            icon: AppIcons.store,
            title: store?.businessName ?? 'Store',
            subtitle: store == null ? null : _areaLine(store),
            actions: const [ShopperCartButton()],
          ),
        ),
        body: body,
      ),
    );
  }

  static String? _areaLine(StorefrontStore store) {
    final parts = [store.lga, store.state].whereType<String>().toList();
    return parts.isEmpty ? null : parts.join(', ');
  }
}

/// Delivery warning, stale-stock note and the store's own note.
class _StoreNotices extends StatelessWidget {
  const _StoreNotices({required this.store});

  final StorefrontStore store;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final notes = <Widget>[
      if (!store.deliversToArea)
        _Notice(
          key: const Key('store-no-delivery'),
          icon: AppIcons.location,
          text: "This store doesn't deliver to your area",
          fill: f.warningTint,
          ink: f.warning,
        ),
      if (store.stockMayBeStale)
        _Notice(
          icon: AppIcons.history,
          text: 'Stock may be out of date',
          fill: f.warningTint,
          ink: f.warning,
        ),
      if (store.onlineNote != null)
        Padding(
          padding: EdgeInsets.only(bottom: context.getRSize(10)),
          child: Text(
            store.onlineNote!,
            style: context.regularStyle(13).copyWith(color: muted),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: notes,
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.text,
    required this.fill,
    required this.ink,
  });

  final IconData icon;
  final String text;
  final Color fill;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(10)),
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Row(
        children: [
          AppIcon(icon, filled: true, size: context.getRSize(18), color: ink),
          SizedBox(width: context.getRSize(8)),
          Expanded(
            child: Text(
              text,
              style: context.semiBoldStyle(13).copyWith(color: t.colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
