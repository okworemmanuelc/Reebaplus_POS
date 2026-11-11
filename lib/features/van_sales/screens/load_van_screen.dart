import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/van_sales/screens/load_product_picker_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_driver_pickers.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// One line the manager is building, before it becomes a [VanLoadLine].
class _DraftLine {
  final ProductDataWithStock product;
  int quantity;
  int loadPriceKobo;

  /// Empty-crate shells going out with this line (spec §11 — counting only).
  /// Typed straight into the field below, so it has no constructor default.
  /// Stays 0 for a business that does not track crates: the field is not shown
  /// (see [_LineCard]), because empties are a Bar/Beverage concept only.
  int shellsOut = 0;

  _DraftLine({
    required this.product,
    required this.quantity,
    required this.loadPriceKobo,
  });

  int get valueKobo => quantity * loadPriceKobo;
}

/// Load Van (#141, PRD #139 / ADR 0019, van-sales spec §4.2–§4.4, §9.1) — and,
/// with [trip] supplied, **Restock** the same van mid-run (#143).
///
/// Pick a driver, a source warehouse, and the goods going on board — each at a
/// **load price defaulting to the retail tier and editable per line**, because
/// the load price is the driver's accountability figure for the whole
/// reconciliation, agreed at the tailgate, not whatever the catalogue says
/// later.
///
/// **Restock is the same screen deliberately.** A restock is not a different
/// kind of event: it is the same dispatch against a trip that already exists
/// (spec §7). Giving it its own screen would mean a second below-cost warning, a
/// second uncosted disclosure and a second shell-memo field, each free to drift
/// from this one. Only two things change in restock mode: the driver and the
/// source warehouse are FIXED by the open trip (v1 is one warehouse per trip),
/// and the write goes to [VanTripsDao.restockTrip] instead of `dispatchLoad`.
///
/// Dispatch is one transaction and is **idempotent on a key this screen mints
/// ONCE** ([_dispatchEventId]) — so a double-tap or a retry after a slow write
/// can never debit the driver twice.
class LoadVanScreen extends ConsumerStatefulWidget {
  /// The van being loaded — always supplied by the Van Sales hub, because a van
  /// appears in no ordinary store picker (#140).
  final String vanStoreId;

  /// The open trip to RESTOCK (#143), or null to open a fresh one. When set,
  /// the driver and the source warehouse are read from it rather than picked.
  final VanTripData? trip;

  const LoadVanScreen({super.key, required this.vanStoreId, this.trip});

  @override
  ConsumerState<LoadVanScreen> createState() => _LoadVanScreenState();
}

class _LoadVanScreenState extends ConsumerState<LoadVanScreen> {
  /// The driver answering for this trip. Required to load (#787): debt sits
  /// with the driver, so a load must name one. Null only on a RESTOCK of an
  /// old trip that was loaded before a driver was required.
  VanDriverData? _driver;
  StoreData? _sourceStore;
  final List<_DraftLine> _lines = [];

  /// True when this is a mid-run restock onto an already-open trip.
  bool get _isRestock => widget.trip != null;

  /// The idempotency key for THIS dispatch (spec §7.1). Minted once, when the
  /// screen opens, and re-used across every retry — that is the whole contract.
  /// Minting it at tap time would defeat the purpose: the second tap would
  /// carry a new key and become a second, real load.
  final String _dispatchEventId = UuidV7.generate();

  /// Product ids whose load price is under what those goods cost. Recomputed
  /// after every line edit. Deliberately only ids — see
  /// [VanTripsDao.productsPricedBelowCost]; the figure never reaches this
  /// screen, so a role behind the cost wall cannot be shown it by accident.
  Set<String> _belowCost = const {};

  bool _submitting = false;

  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;

  /// Pre-fill the driver and the store ONCE each, as soon as their data is
  /// there. Done from build (not initState) because the lists may still be
  /// loading on the first frame, and a pre-fill that only tries once then
  /// leaves both pickers empty: two more taps on every load.
  bool _sourcePrefilled = false;
  bool _driverPrefilled = false;

  void _prefill() {
    final stores = ref.read(allStoresProvider).valueOrNull;
    final trip = widget.trip;
    StoreData? source;
    VanDriverData? driver;
    var sourceReady = false;
    var driverReady = false;

    if (!_sourcePrefilled && stores != null) {
      sourceReady = true;
      if (trip != null) {
        // Restock: decided by the trip already on the road. Reading it from
        // the trip (not a picker) is what stops a restock silently loading
        // from a second warehouse, which v1 does not model.
        for (final s in stores) {
          if (s.id == trip.sourceStoreId) source = s;
        }
      } else {
        // A van loads from a WAREHOUSE, never another van (spec §4.2).
        // Auto-pick when there is only one candidate.
        final warehouses = withoutVans(stores);
        if (warehouses.length == 1) source = warehouses.first;
      }
    }
    if (!_driverPrefilled) {
      // Restock keeps its trip's driver; a new load starts from the van's
      // usual driver, which the manager may change.
      final van = ref.read(storeByIdProvider(widget.vanStoreId));
      final wantedId = trip != null
          ? trip.vanDriverId
          : van.valueOrNull?.vanDriverId;
      if (trip != null || van.hasValue) {
        driver = _driverById(wantedId);
        // Wait for the drivers list when there is a driver to find.
        driverReady = wantedId == null || driver != null;
      }
    }
    if (!sourceReady && !driverReady) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        if (sourceReady && !_sourcePrefilled) {
          _sourcePrefilled = true;
          _sourceStore ??= source;
        }
        if (driverReady && !_driverPrefilled) {
          _driverPrefilled = true;
          _driver ??= driver;
        }
      });
    });
  }

  VanDriverData? _driverById(String? id) {
    if (id == null) return null;
    for (final d in ref.read(vanDriversProvider)) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// "Add a driver" inline; selects the new driver on this load.
  Future<void> _addDriver() async {
    final created = await showAddVanDriverDialog(context, ref);
    if (created == null || !mounted) return;
    setState(() => _driver = created);
  }

  /// Which lines are priced under what the goods cost. Asked ONCE, at
  /// Dispatch (#790): asking on every keystroke made typing lag on a long
  /// load. Cheap and side-effect-free: the DAO peeks the FIFO queue without
  /// drawing it down.
  Future<Set<String>> _computeBelowCost(String sourceStoreId) {
    return ref
        .read(databaseProvider)
        .vanTripsDao
        .productsPricedBelowCost(
          sourceStoreId: sourceStoreId,
          lines: _lines
              .map(
                (l) => VanLoadLine(
                  productId: l.product.product.id,
                  quantity: l.quantity,
                  loadPriceKobo: l.loadPriceKobo,
                ),
              )
              .toList(growable: false),
        );
  }

  /// Open the shop's product grid (#790 step 2) and take back what was
  /// counted there. Prices and crates already set on a line are kept.
  Future<void> _browse(List<ProductDataWithStock> products) async {
    final source = _sourceStore;
    if (source == null) {
      AppNotification.showError(context, 'Choose which store it loads from.');
      return;
    }
    FocusScope.of(context).unfocus();
    final picked = await Navigator.push<Map<String, int>>(
      context,
      MaterialPageRoute(
        builder: (_) => LoadProductPickerScreen(
          sourceStoreId: source.id,
          sourceStoreName: source.name,
          initial: {for (final l in _lines) l.product.product.id: l.quantity},
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final byId = {for (final p in products) p.product.id: p};
    setState(() {
      _lines.removeWhere((l) => (picked[l.product.product.id] ?? 1) <= 0);
      for (final e in picked.entries) {
        if (e.value <= 0) continue;
        final existing = _lines
            .where((l) => l.product.product.id == e.key)
            .firstOrNull;
        if (existing != null) {
          existing.quantity = e.value;
          continue;
        }
        final product = byId[e.key];
        if (product == null) continue;
        _lines.add(
          _DraftLine(
            product: product,
            quantity: e.value,
            loadPriceKobo: product.product.retailerPriceKobo,
          ),
        );
      }
      _belowCost = {
        for (final id in _belowCost)
          if (_lines.any((l) => l.product.product.id == id)) id,
      };
    });
  }

  /// "Same as last load" (#790 step 3): a driver takes much the same goods
  /// each day, so start from what they took last time. Quantities are held at
  /// what is in stock now, and prices are TODAY's shop prices, not last
  /// time's, so a price rise is never loaded at the old figure.
  Future<void> _sameAsLastLoad(List<ProductDataWithStock> products) async {
    final driver = _driver;
    if (driver == null) return;
    final lots = await ref
        .read(databaseProvider)
        .vanTripsDao
        .lastLoadFor(vanDriverId: driver.id, vanStoreId: widget.vanStoreId);
    if (!mounted) return;
    if (lots.isEmpty) {
      AppNotification.showInfo(context, 'No earlier load to copy.');
      return;
    }
    final byId = {for (final p in products) p.product.id: p};
    var leftOut = 0;
    var cutDown = 0;
    final lines = <_DraftLine>[];
    for (final lot in lots) {
      final product = byId[lot.productId];
      final inStock = product?.totalStock.floor() ?? 0;
      if (product == null || inStock < 1) {
        leftOut++;
        continue;
      }
      if (lot.quantity > inStock) cutDown++;
      lines.add(
        _DraftLine(
          product: product,
          quantity: lot.quantity > inStock ? inStock : lot.quantity,
          loadPriceKobo: product.product.retailerPriceKobo,
        )..shellsOut = lot.shellsOut,
      );
    }
    setState(() {
      _lines
        ..clear()
        ..addAll(lines);
      _belowCost = const {};
    });
    if (leftOut > 0 || cutDown > 0) {
      AppNotification.showInfo(
        context,
        [
          if (leftOut > 0)
            '$leftOut ${leftOut == 1 ? 'item is' : 'items are'} out of stock '
                'and left out.',
          if (cutDown > 0)
            '$cutDown ${cutDown == 1 ? 'item was' : 'items were'} cut to '
                'what is in stock.',
        ].join(' '),
      );
    }
  }

  int get _totalValueKobo => _lines.fold<int>(0, (sum, l) => sum + l.valueKobo);

  int get _totalUnits => _lines.fold<int>(0, (sum, l) => sum + l.quantity);

  Future<void> _dispatch() async {
    // Write-boundary re-check (layer 3, hard rule #6).
    if (!Gates.vanManage.allowsNow(ref)) {
      showGateDenied(context, Gates.vanManage);
      return;
    }
    final driver = _driver;
    final source = _sourceStore;
    // #787: a new load needs a driver. A restock keeps its trip's driver,
    // including "none" on a trip loaded before this rule.
    if (!_isRestock && driver == null) {
      AppNotification.showError(context, 'Choose who is taking the van out.');
      return;
    }
    if (source == null) {
      AppNotification.showError(context, 'Choose which store it loads from.');
      return;
    }
    if (_lines.isEmpty) {
      final lex = ref.read(industryLexiconProvider);
      AppNotification.showError(
        context,
        'Add at least one ${lex.itemLower} to the load.',
      );
      return;
    }
    for (final line in _lines) {
      if (line.quantity <= 0) {
        AppNotification.showError(
          context,
          'Every line needs a quantity — check ${line.product.product.name}.',
        );
        return;
      }
      if (line.quantity > line.product.totalStock) {
        AppNotification.showError(
          context,
          'Only ${formatQty(line.product.totalStock)} of '
          '${line.product.product.name} in ${source.name}.',
        );
        return;
      }
    }

    // §9.1 #1 — the below-cost confirmation. It names the products and NEVER
    // the cost figure, so a manager without the cost-price permission still
    // gets the warning without being shown what they may not see.
    final below = await _computeBelowCost(source.id);
    if (!mounted) return;
    setState(() => _belowCost = below);
    if (below.isNotEmpty) {
      final names = _lines
          .where((l) => below.contains(l.product.product.id))
          .map((l) => l.product.product.name)
          .join(', ');
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Priced below cost'),
          content: Text(
            'The price on $names is below what these goods cost you. '
            'Load anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Go back'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Load anyway'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;

    setState(() => _submitting = true);
    try {
      final dao = ref.read(databaseProvider).vanTripsDao;
      final lines = _lines
          .map(
            (l) => VanLoadLine(
              productId: l.product.product.id,
              quantity: l.quantity,
              loadPriceKobo: l.loadPriceKobo,
              shellsOut: l.shellsOut,
            ),
          )
          .toList(growable: false);
      // Both branches carry the SAME key on every attempt — the idempotency
      // contract (spec §7.1). A restock is the same dispatch onto an open trip.
      final result = _isRestock
          ? await dao.restockTrip(
              tripId: widget.trip!.id,
              lines: lines,
              performedBy: currentUser.id,
              dispatchEventId: _dispatchEventId,
            )
          : await dao.dispatchLoad(
              vanStoreId: widget.vanStoreId,
              vanDriverId: driver?.id,
              sourceStoreId: source.id,
              performedBy: currentUser.id,
              dispatchEventId: _dispatchEventId,
              lines: lines,
            );
      if (!mounted) return;

      // §9.1 #2 — an uncosted load is allowed, but it is DISCLOSED. Left
      // silent, those units would look like free goods at close.
      if (result.uncostedProductIds.isNotEmpty) {
        final n = result.uncostedProductIds.length;
        final lex = ref.read(industryLexiconProvider);
        AppNotification.showError(
          context,
          '$n ${n == 1 ? '${lex.itemLower} has' : '${lex.itemPluralLower} have'} '
          'no recorded cost yet, so this trip\'s profit will be understated '
          'until you record one.',
        );
      }
      AppNotification.showSuccess(
        context,
        result.alreadyApplied
            ? _isRestock
                  ? 'This restock was already sent.'
                  : 'This load was already sent.'
            : _isRestock
            ? '${driver?.name ?? 'The van'} signed for '
                  '${formatCurrency(result.totalLoadValueKobo / 100)} more.'
            : '${driver?.name ?? 'The van'} signed for '
                  '${formatCurrency(result.totalLoadValueKobo / 100)}.',
      );
      Navigator.pop(context);
    } on VanTripAlreadyOpenException catch (e) {
      if (!mounted) return;
      AppNotification.showError(context, e.message);
    } on VanTripNotOpenException catch (e) {
      if (!mounted) return;
      AppNotification.showError(context, e.message);
    } on InsufficientStockException catch (_) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Not enough stock in ${source.name} for this load. Nothing was sent.',
      );
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not send the load. Nothing was moved — try again.',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // The trade's own word for a sellable item (ADR 0015). Van sales sells the
    // same catalogue the shop does, so it must speak the same language: a
    // pharmacy loads medicines onto the van, not drinks.
    final lex = ref.watch(industryLexiconProvider);
    // Empties are a Bar/Beverage concept. Every other trade must not be asked
    // to count crates it does not deal in.
    final tracksCrates = businessTracksCrates(
      ref.watch(currentBusinessProvider),
    );
    final vanName =
        ref.watch(storeByIdProvider(widget.vanStoreId)).valueOrNull?.name ??
        'Van';
    final drivers = ref.watch(vanDriversProvider);
    if (!_sourcePrefilled || !_driverPrefilled) _prefill();
    final warehouses = withoutVans(
      ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[],
    );
    final sourceId = _sourceStore?.id;
    final products = sourceId == null
        ? const <ProductDataWithStock>[]
        : (ref.watch(productsByStoreProvider(sourceId)).valueOrNull ??
                  const <ProductDataWithStock>[])
              .where((p) => p.totalStock > 0)
              .toList();

    final side = context.getRSize(20);
    return GlassyScaffold(
      title: _isRestock ? 'Restock Van' : 'Load Van',
      subtitle: vanName,
      // #790: one scroll view, with the add box PINNED so the next item can be
      // added without scrolling back up a long load.
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, side, side, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_isRestock)
                    // Both axes are FIXED by the open trip, so they are stated, not
                    // offered: a restock goes to the driver who is out, from the
                    // warehouse the trip loads from (one per trip in v1, spec §4.2).
                    _FixedTripCard(
                      driverName: _driver?.name ?? 'No driver assigned',
                      sourceName: _sourceStore?.name ?? 'Warehouse',
                    )
                  else ...[
                    // Required (#787). '+' = add a new one.
                    AppDropdown<String>(
                      key: const Key('load-van-driver'),
                      labelText: 'Driver',
                      hintText: 'Who is taking it out?',
                      value: _driver?.id,
                      prefixIcon: Icon(
                        AppIcons.managerRole,
                        size: 14,
                        color: _subtext,
                      ),
                      items: [
                        ...drivers.map(
                          (d) => DropdownMenuItem(
                            value: d.id,
                            child: Text(d.name),
                          ),
                        ),
                        const DropdownMenuItem(
                          value: '+',
                          child: Text('Add a new driver...'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v == '+') {
                          _addDriver();
                        } else {
                          setState(() => _driver = _driverById(v));
                        }
                      },
                    ),
                    SizedBox(height: context.getRSize(16)),

                    AppDropdown<StoreData>(
                      labelText: 'Load from',
                      hintText:
                          'Which store are the ${lex.itemPluralLower} coming '
                          'out of?',
                      value: _sourceStore,
                      prefixIcon: Icon(
                        AppIcons.warehouse,
                        size: 14,
                        color: _subtext,
                      ),
                      items: warehouses
                          .map(
                            (s) =>
                                DropdownMenuItem(value: s, child: Text(s.name)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() {
                        _sourceStore = v;
                        // The lines were priced and stocked against the old store.
                        _lines.clear();
                        _belowCost = const {};
                      }),
                    ),
                  ],
                  SizedBox(height: context.getRSize(20)),
                  Text(
                    _isRestock
                        ? 'What is going on board now'
                        : 'What is going on board',
                    style: t.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.getRSize(4)),
                ],
              ),
            ),
          ),
          PinnedHeaderSliver(
            child: Container(
              // Opaque, so rows scrolling under the pinned button do not show
              // through it.
              color: t.scaffoldBackgroundColor,
              padding: EdgeInsets.symmetric(
                horizontal: side,
                vertical: context.getRSize(6),
              ),
              // The ONE way to add (owner, 2026-11-11): it opens the shop's
              // product grid, with its search, categories and scanner. Pinned,
              // so the next item is always one tap away on a long load.
              child: AppButton(
                key: const Key('load-van-browse'),
                text: _lines.isEmpty
                    ? 'Add ${lex.itemPluralLower}'
                    : 'Add or change ${lex.itemPluralLower}',
                icon: AppIcons.add,
                isFullWidth: true,
                onPressed: _sourceStore == null
                    ? null
                    : () => _browse(products),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, context.getRSize(6), side, 0),
            sliver: _lines.isEmpty
                ? SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: context.getRSize(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Nothing on the load yet.',
                            style: t.textTheme.bodySmall?.copyWith(
                              color: _subtext,
                            ),
                          ),
                          if (!_isRestock &&
                              _driver != null &&
                              _sourceStore != null)
                            TextButton.icon(
                              key: const Key('load-van-same-as-last'),
                              onPressed: () => _sameAsLastLoad(products),
                              icon: const Icon(AppIcons.history, size: 18),
                              label: const Text('Same as last load'),
                            ),
                        ],
                      ),
                    ),
                  )
                : SliverList.builder(
                    itemCount: _lines.length,
                    itemBuilder: (_, i) {
                      final line = _lines[i];
                      final id = line.product.product.id;
                      return _LineRow(
                        key: ValueKey('load-line-$id'),
                        line: line,
                        showCrates: tracksCrates,
                        isBelowCost: _belowCost.contains(id),
                        onChanged: () => setState(() {}),
                        onQtyDone: () => FocusScope.of(context).unfocus(),
                        onRemove: () => setState(() {
                          _lines.remove(line);
                          _belowCost = {..._belowCost}..remove(id);
                        }),
                      );
                    },
                  ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              side,
              context.getRSize(16),
              side,
              side + context.deviceBottomPadding,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                children: [
                  _TotalCard(
                    units: _totalUnits,
                    valueKobo: _totalValueKobo,
                    driverName: _driver?.name,
                  ),
                  SizedBox(height: context.getRSize(20)),
                  AppButton(
                    key: const Key('load-van-send'),
                    text: _submitting
                        ? 'Sending…'
                        : _isRestock
                        ? 'Send Restock'
                        : 'Dispatch Load',
                    icon: AppIcons.vanDelivery,
                    onPressed: _submitting ? null : _dispatch,
                    isFullWidth: true,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Restock mode: the driver and warehouse the open trip already decided,
/// stated rather than offered.
class _FixedTripCard extends StatelessWidget {
  final String driverName;
  final String sourceName;

  const _FixedTripCard({required this.driverName, required this.sourceName});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.managerRole,
                size: context.getRSize(12),
                color: subtext,
              ),
              SizedBox(width: context.getRSize(8)),
              Expanded(
                child: Text(
                  driverName,
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(6)),
          Row(
            children: [
              Icon(
                AppIcons.warehouse,
                size: context.getRSize(12),
                color: subtext,
              ),
              SizedBox(width: context.getRSize(8)),
              Expanded(
                child: Text(
                  'Loading from $sourceName',
                  style: t.textTheme.bodySmall?.copyWith(color: subtext),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One line on the load, compact (#790): the name, a minus / quantity / plus
/// stepper, and the line total. The load price and the crate count are behind
/// "Edit", because the price defaults to the shop price and is rarely changed.
/// A real load is 16 to 30 lines; the old three-box card made that a long
/// scroll and a keyboard trip per line.
class _LineRow extends StatefulWidget {
  final _DraftLine line;

  /// Whether to offer the empty-crate count. Passed down so the whole screen
  /// decides the crate question once.
  final bool showCrates;
  final bool isBelowCost;

  final VoidCallback onChanged;
  final VoidCallback onRemove;

  /// The keyboard's Done on the quantity box.
  final VoidCallback onQtyDone;

  const _LineRow({
    super.key,
    required this.line,
    required this.showCrates,
    required this.isBelowCost,
    required this.onChanged,
    required this.onRemove,
    required this.onQtyDone,
  });

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  late final TextEditingController _qty = TextEditingController(
    text: widget.line.quantity.toString(),
  );
  final FocusNode _qtyFocus = FocusNode();
  bool _editing = false;

  /// The quantity can change outside this row (the product grid). Show it,
  /// unless the box is being typed in.
  @override
  void didUpdateWidget(covariant _LineRow old) {
    super.didUpdateWidget(old);
    final q = widget.line.quantity.toString();
    if (!_qtyFocus.hasFocus && _qty.text != q) _qty.text = q;
  }

  @override
  void dispose() {
    _qty.dispose();
    _qtyFocus.dispose();
    super.dispose();
  }

  void _bump(int by) {
    final line = widget.line;
    final next = line.quantity + by;
    if (next < 1 || next > line.product.totalStock) return;
    line.quantity = next;
    _qty.text = next.toString();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final line = widget.line;
    final id = line.product.product.id;
    final step = BoxConstraints.tightFor(
      width: context.getRSize(40),
      height: context.getRSize(40),
    );

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(8)),
      padding: EdgeInsets.fromLTRB(
        context.getRSize(12),
        context.getRSize(6),
        context.getRSize(4),
        context.getRSize(8),
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.isBelowCost ? semantic.warning : t.dividerColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  line.product.product.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                key: Key('load-edit-$id'),
                constraints: step,
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _editing = !_editing),
                icon: Icon(
                  AppIcons.edit,
                  size: context.getRSize(16),
                  color: _editing ? t.colorScheme.primary : subtext,
                ),
                tooltip: 'Edit price',
              ),
              IconButton(
                key: Key('load-remove-$id'),
                constraints: step,
                padding: EdgeInsets.zero,
                onPressed: widget.onRemove,
                icon: Icon(AppIcons.close, size: context.getRSize(16)),
                tooltip: 'Remove',
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'In stock ${formatQty(line.product.totalStock)}  ·  '
                  '${formatCurrency(line.loadPriceKobo / 100)} each\n'
                  'Line total ${formatCurrency(line.valueKobo / 100)}',
                  key: Key('load-line-info-$id'),
                  style: t.textTheme.bodySmall?.copyWith(color: subtext),
                ),
              ),
              IconButton(
                key: Key('load-minus-$id'),
                constraints: step,
                padding: EdgeInsets.zero,
                onPressed: () => _bump(-1),
                icon: Icon(AppIcons.minus, size: context.getRSize(18)),
                tooltip: 'One less',
              ),
              SizedBox(
                width: context.getRSize(60),
                child: TextField(
                  key: Key('load-qty-$id'),
                  controller: _qty,
                  focusNode: _qtyFocus,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: t.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      vertical: context.getRSize(8),
                    ),
                  ),
                  onTap: () => _qty.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: _qty.text.length,
                  ),
                  onChanged: (v) {
                    line.quantity = int.tryParse(v.trim()) ?? 0;
                    widget.onChanged();
                  },
                  onSubmitted: (_) => widget.onQtyDone(),
                ),
              ),
              IconButton(
                key: Key('load-plus-$id'),
                constraints: step,
                padding: EdgeInsets.zero,
                onPressed: () => _bump(1),
                icon: Icon(AppIcons.add, size: context.getRSize(18)),
                tooltip: 'One more',
              ),
            ],
          ),
          if (_editing) ...[
            SizedBox(height: context.getRSize(10)),
            Padding(
              padding: EdgeInsets.only(right: context.getRSize(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppInput(
                    key: Key('load-price-$id'),
                    // The default is the shop price; this field is why it is
                    // a default and not a rule (spec §4.3).
                    labelText: 'Load price',
                    initialValue: (line.loadPriceKobo / 100).toStringAsFixed(0),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    prefixText: activeCurrencySymbol,
                    onChanged: (v) {
                      line.loadPriceKobo = (int.tryParse(v.trim()) ?? 0) * 100;
                      widget.onChanged();
                    },
                  ),
                  if (widget.showCrates) ...[
                    SizedBox(height: context.getRSize(10)),
                    AppInput(
                      // §11 / #726: the crates that must come home with this
                      // load. Counted back at the return; what is missing
                      // shows as lost crates. No money moves.
                      labelText: 'Crates to bring back (optional)',
                      initialValue: line.shellsOut == 0
                          ? ''
                          : line.shellsOut.toString(),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      hintText: '0',
                      onChanged: (v) {
                        line.shellsOut = int.tryParse(v.trim()) ?? 0;
                        widget.onChanged();
                      },
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      'Crates leaving with this load, including any extra '
                      'empties for swaps. Used to spot lost crates at close.',
                      style: t.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (widget.isBelowCost) ...[
            SizedBox(height: context.getRSize(6)),
            Row(
              children: [
                Icon(
                  AppIcons.warning,
                  size: context.getRSize(12),
                  color: semantic.warning,
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: Text(
                    // NEVER the figure (spec §9.1 #1). The screen is not given
                    // the cost, so it cannot print it.
                    'This price is below what these goods cost you.',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: semantic.warning,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// What the driver is about to sign for.
class _TotalCard extends StatelessWidget {
  final int units;
  final int valueKobo;
  final String? driverName;

  const _TotalCard({
    required this.units,
    required this.valueKobo,
    required this.driverName,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: t.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$units ${units == 1 ? 'unit' : 'units'} on board',
            style: t.textTheme.bodySmall?.copyWith(color: subtext),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            formatCurrency(valueKobo / 100),
            style: t.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            driverName == null
                ? 'The driver signs for this value.'
                : '$driverName signs for this value until it is sold, '
                      'returned or paid in.',
            style: t.textTheme.bodySmall?.copyWith(color: subtext),
          ),
        ],
      ),
    );
  }
}
