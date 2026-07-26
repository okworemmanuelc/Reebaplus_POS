import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
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
  int shellsOut = 0;

  _DraftLine({
    required this.product,
    required this.quantity,
    required this.loadPriceKobo,
  });

  int get valueKobo => quantity * loadPriceKobo;
}

/// Load Van (#141, PRD #139 / ADR 0019, van-sales spec §4.2–§4.4, §9.1).
///
/// Pick a driver, a source warehouse, and the drinks going on board — each at a
/// **load price defaulting to the retail tier and editable per line**, because
/// the load price is the driver's accountability figure for the whole
/// reconciliation, agreed at the tailgate, not whatever the catalogue says
/// later.
///
/// Dispatch is one transaction in [VanTripsDao.dispatchLoad] and is **idempotent
/// on a key this screen mints ONCE** ([_dispatchEventId]) — so a double-tap or a
/// retry after a slow write can never debit the driver twice.
class LoadVanScreen extends ConsumerStatefulWidget {
  /// The van being loaded — always supplied by the Van Sales hub, because a van
  /// appears in no ordinary store picker (#140).
  final String vanStoreId;

  const LoadVanScreen({super.key, required this.vanStoreId});

  @override
  ConsumerState<LoadVanScreen> createState() => _LoadVanScreenState();
}

class _LoadVanScreenState extends ConsumerState<LoadVanScreen> {
  UserData? _driver;
  StoreData? _sourceStore;
  final List<_DraftLine> _lines = [];

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A van loads from a WAREHOUSE, never another van (spec §4.2: one source
      // warehouse per trip). Auto-pick when there is only one candidate.
      final warehouses = withoutVans(
        ref.read(allStoresProvider).valueOrNull ?? const <StoreData>[],
      );
      final drivers = ref.read(vanDriversProvider);
      setState(() {
        if (warehouses.length == 1) _sourceStore = warehouses.first;
        if (drivers.length == 1) _driver = drivers.first;
      });
    });
  }

  /// Re-ask which lines are underwater. Cheap and side-effect-free — the DAO
  /// peeks the FIFO queue without drawing it down.
  Future<void> _refreshBelowCost() async {
    final source = _sourceStore;
    if (source == null || _lines.isEmpty) {
      if (mounted) setState(() => _belowCost = const {});
      return;
    }
    final below = await ref.read(databaseProvider).vanTripsDao
        .productsPricedBelowCost(
      sourceStoreId: source.id,
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
    if (mounted) setState(() => _belowCost = below);
  }

  void _addProduct(ProductDataWithStock product) {
    final existing = _lines.where(
      (l) => l.product.product.id == product.product.id,
    );
    if (existing.isNotEmpty) {
      AppNotification.showError(
        context,
        '${product.product.name} is already on this load — edit its quantity.',
      );
      return;
    }
    setState(() {
      _lines.add(
        _DraftLine(
          product: product,
          quantity: 1,
          // The retail tier is the default (spec §4.3) — and it is a DEFAULT,
          // not a lock: the field below is editable per line.
          loadPriceKobo: product.product.retailerPriceKobo,
        ),
      );
    });
    _refreshBelowCost();
  }

  int get _totalValueKobo =>
      _lines.fold<int>(0, (sum, l) => sum + l.valueKobo);

  int get _totalUnits => _lines.fold<int>(0, (sum, l) => sum + l.quantity);

  Future<void> _dispatch() async {
    // Write-boundary re-check (layer 3, hard rule #6).
    if (!Gates.vanManage.allowsNow(ref)) {
      showGateDenied(context, Gates.vanManage);
      return;
    }
    final driver = _driver;
    final source = _sourceStore;
    if (driver == null) {
      AppNotification.showError(context, 'Choose which driver is taking it.');
      return;
    }
    if (source == null) {
      AppNotification.showError(context, 'Choose which store it loads from.');
      return;
    }
    if (_lines.isEmpty) {
      AppNotification.showError(context, 'Add at least one drink to the load.');
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
          'Only ${line.product.totalStock} of '
          '${line.product.product.name} in ${source.name}.',
        );
        return;
      }
    }

    // §9.1 #1 — the below-cost confirmation. It names the products and NEVER
    // the cost figure, so a manager without the cost-price permission still
    // gets the warning without being shown what they may not see.
    if (_belowCost.isNotEmpty) {
      final names = _lines
          .where((l) => _belowCost.contains(l.product.product.id))
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
      if (proceed != true) return;
    }

    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;

    setState(() => _submitting = true);
    try {
      final result =
          await ref.read(databaseProvider).vanTripsDao.dispatchLoad(
                vanStoreId: widget.vanStoreId,
                driverUserId: driver.id,
                sourceStoreId: source.id,
                performedBy: currentUser.id,
                // The same key on every attempt — the idempotency contract.
                dispatchEventId: _dispatchEventId,
                lines: _lines
                    .map(
                      (l) => VanLoadLine(
                        productId: l.product.product.id,
                        quantity: l.quantity,
                        loadPriceKobo: l.loadPriceKobo,
                        shellsOut: l.shellsOut,
                      ),
                    )
                    .toList(growable: false),
              );
      if (!mounted) return;

      // §9.1 #2 — an uncosted load is allowed, but it is DISCLOSED. Left
      // silent, those units would look like free goods at close.
      if (result.uncostedProductIds.isNotEmpty) {
        final n = result.uncostedProductIds.length;
        AppNotification.showError(
          context,
          '$n ${n == 1 ? 'drink has' : 'drinks have'} no recorded cost yet, '
          'so this trip\'s profit will be understated until you record one.',
        );
      }
      AppNotification.showSuccess(
        context,
        result.alreadyApplied
            ? 'This load was already sent.'
            : '${driver.name} signed for '
                '${formatCurrency(result.totalLoadValueKobo / 100)}.',
      );
      Navigator.pop(context);
    } on VanTripAlreadyOpenException catch (e) {
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
    final vanName = ref
            .watch(storeByIdProvider(widget.vanStoreId))
            .valueOrNull
            ?.name ??
        'Van';
    final drivers = ref.watch(vanDriversProvider);
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

    return GlassyScaffold(
      title: 'Load Van',
      subtitle: vanName,
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20) + context.deviceBottomPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppDropdown<UserData>(
              labelText: 'Driver',
              hintText: drivers.isEmpty
                  ? 'No staff have the Driver role yet'
                  : 'Who is taking it out?',
              value: _driver,
              prefixIcon: Icon(
                FontAwesomeIcons.userTie.data,
                size: 14,
                color: _subtext,
              ),
              items: drivers
                  .map((d) => DropdownMenuItem(value: d, child: Text(d.name)))
                  .toList(),
              onChanged: (v) => setState(() => _driver = v),
            ),
            SizedBox(height: context.getRSize(16)),

            AppDropdown<StoreData>(
              labelText: 'Load from',
              hintText: 'Which store are the drinks coming out of?',
              value: _sourceStore,
              prefixIcon: Icon(
                FontAwesomeIcons.warehouse.data,
                size: 14,
                color: _subtext,
              ),
              items: warehouses
                  .map((s) => DropdownMenuItem(value: s, child: Text(s.name)))
                  .toList(),
              onChanged: (v) => setState(() {
                _sourceStore = v;
                // The lines were priced and stocked against the old store.
                _lines.clear();
                _belowCost = const {};
              }),
            ),
            SizedBox(height: context.getRSize(20)),

            Text(
              'What is going on board',
              style: t.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.getRSize(10)),

            Autocomplete<ProductDataWithStock>(
              displayStringForOption: (p) => p.product.name,
              optionsBuilder: (TextEditingValue v) {
                if (v.text.isEmpty) return const Iterable.empty();
                final q = v.text.toLowerCase();
                return products.where(
                  (p) => p.product.name.toLowerCase().contains(q),
                );
              },
              onSelected: _addProduct,
              fieldViewBuilder: (ctx, controller, focusNode, onEditingComplete) {
                return AppInput(
                  controller: controller,
                  focusNode: focusNode,
                  labelText: 'Add a drink',
                  onFieldSubmitted: (_) => onEditingComplete(),
                  prefixIcon: Icon(
                    FontAwesomeIcons.boxesStacked.data,
                    size: 14,
                    color: _subtext,
                  ),
                  hintText: _sourceStore == null
                      ? 'Pick a store to load from first'
                      : 'Start typing a drink name…',
                  enabled: _sourceStore != null,
                );
              },
            ),
            SizedBox(height: context.getRSize(12)),

            if (_lines.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(16)),
                child: Text(
                  'Nothing on the load yet.',
                  style: t.textTheme.bodySmall?.copyWith(color: _subtext),
                ),
              )
            else
              ..._lines.map(
                (line) => _LineCard(
                  line: line,
                  isBelowCost: _belowCost.contains(line.product.product.id),
                  onChanged: () {
                    setState(() {});
                    _refreshBelowCost();
                  },
                  onRemove: () {
                    setState(() => _lines.remove(line));
                    _refreshBelowCost();
                  },
                ),
              ),

            SizedBox(height: context.getRSize(16)),
            _TotalCard(
              units: _totalUnits,
              valueKobo: _totalValueKobo,
              driverName: _driver?.name,
            ),
            SizedBox(height: context.getRSize(20)),

            AppButton(
              text: _submitting ? 'Sending…' : 'Dispatch Load',
              icon: FontAwesomeIcons.truckFast.data,
              onPressed: _submitting ? null : _dispatch,
              isFullWidth: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// One drink on the load: quantity, the editable load price, and the shell memo
/// count.
class _LineCard extends StatelessWidget {
  final _DraftLine line;
  final bool isBelowCost;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _LineCard({
    required this.line,
    required this.isBelowCost,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(10)),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isBelowCost ? semantic.warning : t.dividerColor,
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
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                onPressed: onRemove,
                icon: Icon(
                  FontAwesomeIcons.xmark.data,
                  size: context.getRSize(14),
                ),
                tooltip: 'Remove',
              ),
            ],
          ),
          Text(
            'In stock: ${line.product.totalStock}',
            style: t.textTheme.bodySmall?.copyWith(color: subtext),
          ),
          SizedBox(height: context.getRSize(10)),
          Row(
            children: [
              Expanded(
                child: AppInput(
                  labelText: 'Quantity',
                  initialValue: line.quantity.toString(),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (v) {
                    line.quantity = int.tryParse(v.trim()) ?? 0;
                    onChanged();
                  },
                ),
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: AppInput(
                  // The default is the retail tier; this field is why it is a
                  // default and not a rule (spec §4.3).
                  labelText: 'Load price',
                  initialValue: (line.loadPriceKobo / 100).toStringAsFixed(0),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  prefixText: activeCurrencySymbol,
                  onChanged: (v) {
                    line.loadPriceKobo = (int.tryParse(v.trim()) ?? 0) * 100;
                    onChanged();
                  },
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(10)),
          AppInput(
            // §11 — counting only. No deposit money moves in v1; the count
            // exists so a trip can't close "settled" having lost every shell.
            labelText: 'Empty crates going out (optional)',
            initialValue: line.shellsOut == 0 ? '' : line.shellsOut.toString(),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            hintText: '0',
            onChanged: (v) {
              line.shellsOut = int.tryParse(v.trim()) ?? 0;
              onChanged();
            },
          ),
          if (isBelowCost) ...[
            SizedBox(height: context.getRSize(10)),
            Row(
              children: [
                Icon(
                  FontAwesomeIcons.triangleExclamation.data,
                  size: context.getRSize(12),
                  color: semantic.warning,
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: Text(
                    // NEVER the figure — spec §9.1 #1. The screen is not given
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
          SizedBox(height: context.getRSize(8)),
          Text(
            'Line total ${formatCurrency(line.valueKobo / 100)}',
            style: t.textTheme.bodySmall?.copyWith(color: subtext),
          ),
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
