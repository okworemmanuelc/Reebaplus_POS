import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/constants/category_filter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/coach_hint_banner.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/screen_header.dart';
import 'package:reebaplus_pos/shared/widgets/view_selector_sheet.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/controllers/pos_controller.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/features/pos/widgets/category_filter_bar.dart';
import 'package:reebaplus_pos/features/pos/widgets/pos_header_parts.dart';
import 'package:reebaplus_pos/features/pos/widgets/quick_sale_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/pos_barcode_scan_button.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';

import 'package:reebaplus_pos/shared/widgets/store_picker_sheet.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/shared/services/ui_hint_service.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';

export 'package:reebaplus_pos/features/pos/widgets/pos_header_parts.dart'
    show kPosTopBarKey, kPosViewSelectorKey, kPosHintKey, kPosSelectStoreKey;

/// POS's one vertical scroll surface (issue #259 / PRD #239).
const Key kPosScrollSurfaceKey = ValueKey<String>('pos-scroll-surface');

/// The price-tier / manufacturer / quick-sale row. Scrolls away.
const Key kPosTierRowKey = ValueKey<String>('pos-tier-row');

/// The search bar + category chips band. Freezes at the top.
const Key kPosSearchBandKey = ValueKey<String>('pos-search-band');

const Key kPosTierDropdownKey = ValueKey<String>('pos-tier-dropdown');
const Key kPosManufacturerDropdownKey = ValueKey<String>(
  'pos-manufacturer-dropdown',
);
const Key kPosQuickSaleKey = ValueKey<String>('pos-quick-sale');
const Key kPosScannerKey = ValueKey<String>('pos-scanner');
const Key kPosSearchFieldKey = ValueKey<String>('pos-search-field');
const Key kPosCategoryChipsKey = ValueKey<String>('pos-category-chips');

/// Every control that must still exist with the phone held sideways.
///
/// "Nothing is removed in landscape" (PRD #239): density drops and the layout
/// re-flows, but no control is hidden, collapsed behind a menu, or gated on
/// orientation. Each of these may scroll out of view; none may disappear.
const List<Key> kPosLandscapeControlKeys = [
  kPosTierDropdownKey,
  kPosManufacturerDropdownKey,
  kPosQuickSaleKey,
  kPosScannerKey,
  kPosSearchFieldKey,
  kPosCategoryChipsKey,
];

class PosHomeScreen extends ConsumerStatefulWidget {
  const PosHomeScreen({super.key});

  @override
  ConsumerState<PosHomeScreen> createState() => _PosHomeScreenState();
}

class _PosHomeScreenState extends ConsumerState<PosHomeScreen> {
  PosController? _controller;
  final TextEditingController _searchController = TextEditingController();
  bool _hasAutoShownPicker = false;
  bool _isListView = false;
  // #384: 2 columns on an upright phone by default (the mockup); a saved
  // view-selector choice still wins.
  int _gridColumns = 2;
  bool _showPosHint = false;

  @override
  void initState() {
    super.initState();
    _loadViewPreferences();
    // One combined POS coach banner (tap = add to cart, hold = choose quantity),
    // so POS never stacks two coach tips. Counted as a passive view on display so
    // an ignored banner still self-retires after `_retireAfter` visits.
    uiHintService.shouldShow(UiHintService.hintPosGestures).then((show) {
      if (show && mounted) {
        setState(() => _showPosHint = true);
        uiHintService.markShown(UiHintService.hintPosGestures);
      }
    });
    Future.microtask(() {
      if (!mounted) return;
      setState(() {
        _controller = PosController(
          database: ref.read(databaseProvider),
          navigationService: ref.read(navigationProvider),
          cartService: ref.read(cartProvider),
        );
      });
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadViewPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isListView = prefs.getBool('pos_is_list_view') ?? false;
        _gridColumns = prefs.getInt('pos_grid_columns') ?? 2;
      });
    }
  }

  Future<void> _updateViewPreferences({bool? isList, int? columns}) async {
    final prefs = await SharedPreferences.getInstance();
    if (isList != null) {
      await prefs.setBool('pos_is_list_view', isList);
      if (mounted) setState(() => _isListView = isList);
    }
    if (columns != null) {
      await prefs.setInt('pos_grid_columns', columns);
      if (mounted) setState(() => _gridColumns = columns);
    }
  }

  void _showViewSelectorModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ViewSelectorSheet(
        currentIsList: _isListView,
        currentColumns: _gridColumns,
        onSelect: (isList, columns) async {
          _updateViewPreferences(isList: isList, columns: columns);
          Navigator.pop(context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    // §12 / hard rule #6: POS is gated to roles that hold `sales.make` (CEO,
    // Manager, Cashier); Stock keeper is already hidden in the sidebar, so this
    // is defense-in-depth against deep-links / bottom-nav. Guarded.screen owns
    // the whole decision now: it waits for the permission set to resolve before
    // rendering (no denial flash — on a fresh login the grants arrive a frame or
    // two late, and an empty set reads the same as "denied"; the CEO must never
    // see "You don't have access to Point of Sale." flash), then shows the body
    // or the standard no-access. POS is a bottom-nav tab, so the loading/denied
    // surfaces keep the SharedScaffold chrome (nav stays reachable) instead of
    // the default full-screen scaffold.
    return Guarded.screen(
      gate: Gates.makeSale,
      loading: SharedScaffold(
        activeRoute: 'pos',
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const SafeArea(child: SizedBox.shrink()),
      ),
      denied: SharedScaffold(
        activeRoute: 'pos',
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: Text(
              'You don\'t have access to Point of Sale.',
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ),
      builder: _buildPos,
    );
  }

  /// The POS body, shown once [Gates.makeSale] has resolved and granted. Split
  /// out of [build] so the `Guarded.screen` guard above owns the
  /// permissions-ready / denial decision (no denial flash on fresh login).
  Widget _buildPos(BuildContext context) {
    // §12.1: POS always sells from one concrete store. Any user with more than
    // one store must explicitly pick the store they're selling from before POS
    // will sell — both an all-stores viewer on "All Stores" (active store null)
    // and a confined multi-store user that MainLayout pinned to a silent default
    // (active store set, but not explicitly chosen). Don't silently sell from a
    // default store; gate behind an explicit pick. Choosing one sets the global
    // active store (`lockedStoreId`), which the sidebar picker reflects too.
    final selectable = ref.watch(selectableStoresProvider);
    final activeStoreId = ref.watch(lockedStoreProvider).value;
    final storeChosen = ref.watch(storeExplicitlyChosenProvider).value;
    // True while a multi-store user is on "All Stores" (active store null) or
    // hasn't explicitly picked the store they're selling from. While this holds
    // the picker is up; the grid behind it must NOT render real products — show a
    // "pick a store" placeholder instead so nothing is accidentally sold from a
    // silent default / the wrong store.
    final needsStoreSelection =
        selectable.length >= 2 && (activeStoreId == null || !storeChosen);
    if (needsStoreSelection) {
      if (!_hasAutoShownPicker) {
        _hasAutoShownPicker = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final currentActive = ref.read(lockedStoreProvider).value;
          final currentChosen = ref.read(storeExplicitlyChosenProvider).value;
          if (currentActive == null || !currentChosen) {
            showStorePickerSheet(context, ref, isDismissible: false);
          }
        });
      }
    }

    if (_controller == null) {
      final bgCol = Theme.of(context).scaffoldBackgroundColor;
      return SharedScaffold(
        activeRoute: 'pos',
        backgroundColor: bgCol,
        body: const SafeArea(child: SizedBox.shrink()),
      );
    }

    // §12.1: POS always sells from one concrete store. Keep the controller's
    // "All Stores" fallback in sync with the user's first selectable store so the
    // grid + checkout always have a real store. Reached when a store is active,
    // or when there's only one selectable store (the "no active store + ≥2
    // stores" case is gated above); the fallback covers the lone-store user.
    // Deferred to post-frame because setFallbackStore can re-subscribe + notify.
    final fallback = selectable.isNotEmpty ? selectable.first.id : null;
    if (_controller!.fallbackStoreId != fallback) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller?.setFallbackStore(fallback);
      });
    }

    return ListenableBuilder(
      listenable: _controller!,
      builder: (context, _) {
        // #384: the page sits on the shared soft fade; the top bar is solid
        // Surface and the frozen band takes the fade's top colour, so the grid
        // scrolls under an opaque strip.
        return DecoratedBox(
          decoration: AppDecorations.pageBackground(context),
          child: SharedScaffold(
            activeRoute: 'pos',
            backgroundColor: Colors.transparent,
            // The top bar is a sliver in the body's own scroll view now, so the
            // Scaffold must not render one as fixed chrome (issue #259).
            bodyOwnsAppBar: true,
            // The top bar lives inside the scroll view, so this SafeArea owns
            // the status-bar inset the Scaffold's AppBar used to absorb.
            body: SafeArea(
              // Pull-to-refresh wraps the WHOLE body (above the header) so the
              // gesture + spinner work from the very top of the screen, over
              // the dropdowns and category bar — not just on the product grid.
              child: AppRefreshWrapper(
                // POS is ONE scrolling surface (issue #259 / PRD #239). The top
                // bar and the price-tier row scroll away; the search bar and
                // category chips freeze at the top; the grid is a sliver that
                // depends on no supplied height. That last part is the fix: the
                // grid used to sit in an `Expanded` under a non-scrolling
                // Column of fixed chrome, and at 800x360 that chrome took the
                // whole viewport and left the grid 0.0dp — rendering nothing
                // and reporting nothing.
                child: CustomScrollView(
                  key: kPosScrollSurfaceKey,
                  slivers: [
                    _buildTopBarSliver(context),
                    SliverToBoxAdapter(child: _buildHeader(context)),
                    _buildFrozenBandSliver(context, needsStoreSelection),
                    // ONE combined coach banner. Tap adds to the cart;
                    // tap-and-hold opens the qty/discount sheet to add several
                    // at once (it does NOT edit the product — that's done from
                    // the Products screen), which is why the copy says
                    // "quantity", not "edit". Both gestures act on a product
                    // tile, so gate on a non-empty grid.
                    //
                    // It carries ONE hint key. Main had already merged the two
                    // banners into one widget but left them on two
                    // independently retiring keys, which is what made the ✕ a
                    // half-dismiss: it called `markShown` on each, moving both
                    // counts 0 → 1, so the banner came back once more. One key
                    // + `markDismissed` is what makes a close final (see
                    // `UiHintService.hintPosGestures`).
                    if (!_controller!.isLoading &&
                        _showPosHint &&
                        !needsStoreSelection &&
                        _controller!.filteredProducts.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            context.getRSize(16),
                            0,
                            context.getRSize(16),
                            context.getRSize(12),
                          ),
                          child: CoachHintBanner(
                            key: kPosHintKey,
                            message:
                                'Tap a '
                                '${ref.watch(industryLexiconProvider).itemLower}'
                                ' to add it to the cart, or tap and hold to'
                                ' choose a quantity.',
                            onDismiss: () {
                              setState(() => _showPosHint = false);
                              // Deliberate close retires the hint immediately
                              // so it never reappears.
                              uiHintService.markDismissed(
                                UiHintService.hintPosGestures,
                              );
                            },
                          ),
                        ),
                      ),
                    _buildContentSliver(context, needsStoreSelection),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The top bar (menu, "Point of Sale", store subtitle, view selector, bell)
  /// as a sliver.
  ///
  /// Sideways it floats: it scrolls away while the cashier browses and slides
  /// back the moment they scroll the other way, without waiting for the top of
  /// the grid. Upright it is pinned, which is how the Scaffold's fixed `AppBar`
  /// behaved before — POS looks unchanged on the phones staff already use.
  ///
  /// The float is a [SliverPersistentHeader] with no snap, deliberately *not*
  /// Flutter's [SliverFloatingHeader]. That widget snaps by listening to the
  /// scroll position's `isScrollingNotifier` and reads its child's size when
  /// scrolling stops. If the viewport changes size as a fling runs out — a
  /// rotation, or #258's bottom bar handing its 56dp back over 200ms — the
  /// fling ends *inside* `RenderViewport.performLayout`, the listener fires
  /// there, and the read trips `RenderBox.size accessed beyond the scope of
  /// resize, layout, or permitted parent access`. POS stays mounted in the tab
  /// stack, so that fired on rotation from any tab. The unsnapped header's own
  /// scrolling listener returns before touching any size when there is no snap
  /// configuration. The bar still follows the finger back in; it just no longer
  /// finishes the motion on its own when the finger lifts.
  ///
  /// This orientation branch is the deliberate navigation exception recorded on
  /// PRD #239 (amendment 3), the same one the bottom bar takes in #258. It is
  /// *not* a layout gate: the scrolling structure below is unconditional, and
  /// no viewport depends on a hidden bar to avoid overflowing.
  Widget _buildTopBarSliver(BuildContext context) {
    final topBar = _buildAppBar(context);
    // Exactly what Scaffold does with an AppBar: lay it out at its own
    // preferred height, which already answers for the text scale.
    final bar = SizedBox(height: topBar.preferredSize.height, child: topBar);

    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return isLandscape
        ? SliverPersistentHeader(
            floating: true,
            delegate: _FloatingTopBarDelegate(
              extent: topBar.preferredSize.height,
              child: bar,
            ),
          )
        : PinnedHeaderSliver(child: bar);
  }

  /// The search bar (+ scan) and category chips, frozen at the top of the
  /// scroll view.
  ///
  /// [PinnedHeaderSliver] pins the band at its own natural height, so there is
  /// no declared extent to keep in step with the responsive scale — the trap
  /// that a hand-written `SliverPersistentHeaderDelegate` sets, where a child
  /// that renders taller than its declared `maxExtent` is clipped or overflows.
  ///
  /// Search and category filtering stay one tap away while browsing, which is
  /// what makes it acceptable for the price-tier row above to scroll off.
  Widget _buildFrozenBandSliver(
    BuildContext context,
    bool needsStoreSelection,
  ) {
    final gutter = context.getRSize(16);
    return PinnedHeaderSliver(
      child: Container(
        key: kPosSearchBandKey,
        // Opaque: the grid scrolls underneath this band. The page fade's top
        // colour, so the band reads as part of the page (mockups).
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // #111: the search field is always visible — no show/hide toggle,
            // no app-bar search icon. #384: the scan control sits beside it
            // (square on a phone, a "Scan Barcode" pill at 600dp+). Hidden
            // only while a multi-store user still has to pick a store —
            // there's no catalogue loaded to scan into yet.
            Padding(
              // The chips below keep their own 48dp tap height, so the
              // visible gap above and below a chip is already built in.
              padding: EdgeInsets.fromLTRB(
                gutter,
                0,
                gutter,
                context.getRSize(4),
              ),
              child: Row(
                children: [
                  Expanded(child: _buildSearchField()),
                  if (!needsStoreSelection) ...[
                    SizedBox(width: context.getRSize(12)),
                    PosBarcodeScanButton(
                      key: kPosScannerKey,
                      shape: context.isRailLayout
                          ? PosScanButtonShape.pill
                          : PosScanButtonShape.square,
                      tier: _controller!.selectedGroup,
                      loadedProducts: _controller!.allProducts,
                      storeName: _controller!.currentStoreName,
                      storeId: _controller!.activeStoreId,
                      readStoreProducts: () => _controller!.allProducts,
                    ),
                  ],
                ],
              ),
            ),
            if (!_controller!.isLoading)
              CategoryFilterBar(
                key: kPosCategoryChipsKey,
                categories: [
                  'All',
                  ..._controller!.categories.map((c) => c.name),
                  // #109: bucket for products with no category.
                  'Uncategorized',
                ],
                // Defense-in-depth: the controller already resets a dangling
                // selectedCategoryId, but never let the chip label `firstWhere`
                // throw if the selected category is momentarily absent from the
                // list — fall back to 'All'.
                selectedCategory: _selectedCategoryLabel(),
                onCategorySelected: (name) {
                  if (name == 'All') {
                    _controller!.selectCategory(null);
                  } else if (name == 'Uncategorized') {
                    _controller!.selectCategory(kUncategorizedCategoryId);
                  } else {
                    final cat = _controller!.categories.firstWhere(
                      (c) => c.name == name,
                    );
                    _controller!.selectCategory(cat.id);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  /// The scrolling content under the frozen band: the product grid, or the
  /// surface that stands in for it.
  ///
  /// Every branch is a sliver and none depends on a supplied height. The two
  /// full-screen stand-ins use `SliverFillRemaining(hasScrollBody: false)`,
  /// which sizes to the LARGER of the remaining viewport and the child's own
  /// height — so each still centres on a roomy phone and scrolls, rather than
  /// overflowing, once the chrome above has eaten the screen.
  Widget _buildContentSliver(BuildContext context, bool needsStoreSelection) {
    if (needsStoreSelection) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _buildSelectStorePlaceholder(context),
      );
    }
    if (_controller!.isLoading) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    // When the visible grid is empty AND the catalogue is genuinely empty (not
    // a category/search miss), hand off to the persona-aware first-run empty
    // state (the "Add your first product" CTA / neutral message — Seam 2, #34).
    // A filter miss keeps ProductGrid's own "No products found" copy.
    //
    // FirstRunEmptyState itself is deliberately untouched (PRD #239, Out of
    // Scope): seven of its nine host screens hand it the whole body and it fits
    // with room to spare.
    final showFirstRunEmptyState =
        _controller!.filteredProducts.isEmpty &&
        ref.watch(firstRunSurfaceStateProvider) !=
            FirstRunSurfaceState.hasContent;

    final content = showFirstRunEmptyState
        ? const SliverFillRemaining(
            hasScrollBody: false,
            child: FirstRunEmptyState(),
          )
        : ProductGrid(
            products: _controller!.filteredProducts,
            onProductTap: (item) => _addToCart(context, item),
            controller: _controller!,
            isListView: _isListView,
            gridColumns: _gridColumns,
          );

    // §12.5: subtle fade-in for content, no spinner. SliverOpacity rather than
    // Opacity, because the child is a sliver now.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 250),
      builder: (_, v, child) =>
          SliverOpacity(opacity: v, sliver: child as Widget),
      child: content,
    );
  }

  // Shown in place of the product grid while a multi-store user is on "All
  // Stores" / hasn't picked the store they're selling from. The picker sheet is
  // up on top of this; tapping the placeholder re-opens it if dismissed.
  // #384: the empty-state look (a neutral IconTile, muted text, a primary text
  // button); wording unchanged.
  Widget _buildSelectStorePlaceholder(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.getRSize(32)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const IconTile(
              icon: AppIcons.store,
              tone: IconTileTone.neutral,
              size: 56,
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              'Please select a store to view POS products.',
              textAlign: TextAlign.center,
              style: context.regularStyle(15).copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(12)),
            TextButton.icon(
              key: kPosSelectStoreKey,
              style: TextButton.styleFrom(
                minimumSize: const Size(
                  kMinInteractiveDimension,
                  kMinInteractiveDimension,
                ),
              ),
              onPressed: () =>
                  showStorePickerSheet(context, ref, isDismissible: false),
              icon: AppIcon(
                AppIcons.store,
                size: context.getRSize(16),
                color: t.colorScheme.primary,
              ),
              label: Text(
                'Select store',
                style: context
                    .semiBoldStyle(14)
                    .copyWith(color: t.colorScheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Chip label for the active category filter. A plain lookup that falls back
  // to 'All' rather than `firstWhere` (which throws StateError when the
  // selected category is momentarily missing from the list — e.g. right after
  // a soft-delete/console removal syncs down before the selection resets).
  String _selectedCategoryLabel() {
    final id = _controller!.selectedCategoryId;
    if (id == null) return 'All';
    if (id == kUncategorizedCategoryId) return 'Uncategorized';
    for (final c in _controller!.categories) {
      if (c.id == id) return c.name;
    }
    return 'All';
  }

  /// The solid top bar (#384, `phone-pos-*.png` / `tablet-pos-*.png`): the
  /// shared [ScreenHeader] — gradient POS tile, "Point of Sale", the store POS
  /// sells from as the subtitle — then the view selector (grid / list, not in
  /// the mockup, kept) and the live bell. The menu button only under 600dp.
  PreferredSizeWidget _buildAppBar(BuildContext context) {
    // §12.1: the store selector lives in the navigation drawer (above Home),
    // not on the POS header. POS just reflects the store it's selling from
    // (the controller's current store name, which already resolves the "All
    // Stores" fallback).
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final gap = context.getRSize(4);
    return PosTopBar(
      height: posTopBarHeight(context),
      header: ScreenHeader(
        icon: AppIcons.pos,
        title: 'Point of Sale',
        subtitle:
            _controller!.currentStoreName ??
            ref.watch(activeStoreLabelProvider),
        leading: context.isRailLayout
            ? null
            : const SizedBox.square(
                dimension: kMinInteractiveDimension,
                child: MenuButton(),
              ),
        actions: [
          SizedBox(width: gap),
          IconButton(
            key: kPosViewSelectorKey,
            tooltip: 'Select View Layout',
            constraints: const BoxConstraints(
              minWidth: kMinInteractiveDimension,
              minHeight: kMinInteractiveDimension,
            ),
            icon: AppIcon(
              _isListView ? AppIcons.list : AppIcons.grid,
              size: context.getRSize(22),
              color: muted,
            ),
            onPressed: _showViewSelectorModal,
          ),
          SizedBox(width: gap),
          const PosLiveBell(),
        ],
      ),
    );
  }

  /// The price tier, manufacturer filter and Quick Sale — on today's screen,
  /// not in the mockups, so kept (#384) in their own row between the top bar
  /// and the frozen search band. It scrolls away, as before.
  Widget _buildHeader(BuildContext context) {
    // §12.2: CEO/Manager switch price tier freely; Cashier is locked to
    // Retailer (a selected wholesaler customer still auto-applies via the
    // controller's customer listener).
    final slug = ref.watch(currentUserRoleProvider)?.slug;
    final canSwitchTier = slug == 'ceo' || slug == 'manager';
    final gutter = context.getRSize(16);
    return Padding(
      key: kPosTierRowKey,
      padding: EdgeInsets.fromLTRB(
        gutter,
        gutter,
        gutter,
        context.getRSize(12),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: _controller!.isLoading
                ? const SizedBox.shrink()
                : IgnorePointer(
                    ignoring: !canSwitchTier,
                    child: Opacity(
                      opacity: canSwitchTier ? 1.0 : 0.6,
                      child: AppDropdown<PriceTier>(
                        key: kPosTierDropdownKey,
                        value: _controller!.selectedGroup,
                        items: const [
                          DropdownMenuItem(
                            value: PriceTier.retailer,
                            child: Text('Retailer'),
                          ),
                          DropdownMenuItem(
                            value: PriceTier.wholesaler,
                            child: Text('Wholesaler'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) _controller!.selectGroup(val);
                        },
                      ),
                    ),
                  ),
          ),
          SizedBox(width: context.getRSize(8)),
          Expanded(
            flex: 5,
            child: _controller!.isLoading
                ? const SizedBox.shrink()
                : AppDropdown<String>(
                    key: kPosManufacturerDropdownKey,
                    value: _controller!.selectedManufacturerId,
                    items: [
                      const DropdownMenuItem(value: 'All', child: Text('All')),
                      ..._controller!.manufacturers.map(
                        (m) => DropdownMenuItem(
                          value: m.id.toString(),
                          child: Text(m.name),
                        ),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) _controller!.selectManufacturer(val);
                    },
                  ),
          ),
          SizedBox(width: context.getRSize(8)),
          PosQuickSaleButton(
            key: kPosQuickSaleKey,
            onPressed: () => _showQuickSaleModal(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return AppInput(
      key: kPosSearchFieldKey,
      controller: _searchController,
      // #111: the field is always visible, so it must not steal focus and pop
      // the keyboard every time POS opens — the cashier taps it when they want
      // to search.
      onChanged: (v) => _controller!.updateSearch(v),
      hintText:
          'Search ${ref.watch(industryLexiconProvider).itemPluralLower}...',
      prefixIcon: AppIcon(
        AppIcons.search,
        size: context.getRSize(22),
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  void _addToCart(BuildContext context, ProductDataWithStock item) {
    final accepted = ref
        .read(cartProvider)
        .addItem(
          item.product,
          qty: 1.0,
          maxStock: item.totalStock,
          tier: _controller!.selectedGroup,
        );
    if (accepted) {
      AppNotification.showSuccess(
        context,
        '${item.product.name} added to cart',
      );
    } else {
      AppNotification.showError(
        context,
        'Stock limit reached for ${item.product.name}',
      );
    }
  }

  Future<void> _showQuickSaleModal(BuildContext context) async {
    // §12.3 / §12.3.1: CEO and Manager add a Quick Sale straight to the cart.
    // A role below Manager no longer enters a PIN — the modal records an
    // approval request and waits for a Manager/CEO to approve it (the item then
    // drops into the cart) or reject it (the modal closes).
    final slug = ref.read(currentUserRoleProvider)?.slug;
    final requireApproval = slug != 'ceo' && slug != 'manager';

    showDialog(
      context: context,
      // While waiting for approval the modal must not be dismissable by tapping
      // outside — the pending request is withdrawn explicitly via Cancel/back.
      barrierDismissible: !requireApproval,
      builder: (ctx) => QuickSaleModal(
        surfaceCol: Theme.of(context).colorScheme.surface,
        textCol: Theme.of(context).colorScheme.onSurface,
        subtextCol:
            (Theme.of(context).textTheme.bodySmall?.color ??
            Theme.of(context).iconTheme.color!),
        cardCol: Theme.of(context).cardColor,
        isDark: Theme.of(context).brightness == Brightness.dark,
        requireApproval: requireApproval,
      ),
    );
  }
}

/// The sideways top bar's float, without snapping. See
/// `_PosHomeScreenState._buildTopBarSliver` for why this is not
/// [SliverFloatingHeader].
///
/// `minExtent == maxExtent` so the bar slides off whole rather than shrinking,
/// and [child] is already sized to [extent], so its rendered height always
/// matches the declared one.
class _FloatingTopBarDelegate extends SliverPersistentHeaderDelegate {
  const _FloatingTopBarDelegate({required this.extent, required this.child});

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  /// The child is built fresh from screen state on every host build, so it
  /// has to be part of the comparison (see `PinnedTabBarDelegate`).
  @override
  bool shouldRebuild(_FloatingTopBarDelegate oldDelegate) =>
      oldDelegate.extent != extent || oldDelegate.child != child;
}
