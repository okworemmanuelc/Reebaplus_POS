import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// The per-store Stock Transfer hub (§16.8.2) embedded in a store's details for
/// a viewer with full access to that store. Four sections, each hidden when
/// empty:
///   1. Requests to fulfil — pending requests from other stores for THIS store
///      to send (Accept & dispatch / Reject, gated `stores.dispatch_transfer`).
///   2. Incoming stock — in_transit transfers arriving here (Confirm Receipt,
///      gated `stores.receive_transfer`).
///   3. Your requests — pending requests THIS store raised, awaiting dispatch.
///   4. Dispatched out — in_transit transfers sent FROM here (Cancel, gated
///      `stores.dispatch_transfer`).
class StoreTransferHub extends ConsumerWidget {
  final String storeId;

  const StoreTransferHub({super.key, required this.storeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incomingReqs =
        ref.watch(storeIncomingRequestsProvider(storeId)).valueOrNull ??
            const <StockTransferData>[];
    final incomingTransfers =
        ref.watch(storeIncomingTransfersProvider(storeId)).valueOrNull ??
            const <StockTransferData>[];
    final outgoingReqs =
        ref.watch(storeOutgoingRequestsProvider(storeId)).valueOrNull ??
            const <StockTransferData>[];
    final outgoingTransfers =
        ref.watch(storeOutgoingTransfersProvider(storeId)).valueOrNull ??
            const <StockTransferData>[];

    final products =
        ref.watch(productsWithStockProvider(null)).valueOrNull ??
            const <ProductDataWithStock>[];
    final productNames = {
      for (final p in products) p.product.id: p.product.name,
    };
    final productMap = {
      for (final p in products) p.product.id: p.product,
    };
    final emptiesMap = ref.watch(storeEmptiesByManufacturerProvider(storeId)).valueOrNull ?? const <String, int>{};
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final storeNames = {for (final s in stores) s.id: s.name};
    final users =
        ref.watch(usersByBusinessProvider).valueOrNull ?? const <String, UserData>{};

    // Stock-on-hand at THIS store, for the Accept dialog's availability hint.
    final hereStock = {
      for (final p in ref
              .watch(productsByStoreProvider(storeId))
              .valueOrNull ??
          const <ProductDataWithStock>[])
        p.product.id: p.totalStock,
    };

    final text = Theme.of(context).colorScheme.onSurface;
    final subtext = Theme.of(context).textTheme.bodySmall?.color;

    final hasAny = incomingReqs.isNotEmpty ||
        incomingTransfers.isNotEmpty ||
        outgoingReqs.isNotEmpty ||
        outgoingTransfers.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Stock Transfers',
          style: TextStyle(
            fontSize: context.getRFontSize(16),
            fontWeight: FontWeight.bold,
            color: text,
          ),
        ),
        SizedBox(height: context.getRSize(12)),
        if (!hasAny)
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(context.getRSize(16)),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Text(
              'No active transfers for this store.',
              style: TextStyle(
                color: subtext,
                fontSize: context.getRFontSize(13),
              ),
            ),
          ),
        _section(
          context,
          title: 'Requests to fulfil',
          rows: incomingReqs,
          builder: (t) {
            final p = productMap[t.productId];
            final manufacturerId = p?.manufacturerId;
            final isCrateEligible = p != null && p.unit.toLowerCase() == 'bottle' && p.trackEmpties;
            final availableEmpties = manufacturerId != null ? (emptiesMap[manufacturerId] ?? 0) : 0;
            return _TransferActionCard(
              transfer: t,
              mode: _CardMode.fulfil,
              productName: productNames[t.productId] ?? 'Product',
              counterpartyStore: storeNames[t.toLocationId] ?? 'a store',
              byUser: users[t.initiatedBy]?.name,
              availableHere: hereStock[t.productId] ?? 0,
              manufacturerId: manufacturerId,
              isCrateEligible: isCrateEligible,
              availableEmpties: availableEmpties,
            );
          },
        ),
        _section(
          context,
          title: 'Incoming stock',
          rows: incomingTransfers,
          builder: (t) => _TransferActionCard(
            transfer: t,
            mode: _CardMode.receive,
            productName: productNames[t.productId] ?? 'Product',
            counterpartyStore: storeNames[t.fromLocationId] ?? 'a store',
            byUser: users[t.initiatedBy]?.name,
          ),
        ),
        _section(
          context,
          title: 'Your requests',
          rows: outgoingReqs,
          builder: (t) => _TransferActionCard(
            transfer: t,
            mode: _CardMode.requested,
            productName: productNames[t.productId] ?? 'Product',
            counterpartyStore: storeNames[t.fromLocationId] ?? 'a store',
            byUser: users[t.initiatedBy]?.name,
          ),
        ),
        _section(
          context,
          title: 'Dispatched out',
          rows: outgoingTransfers,
          builder: (t) => _TransferActionCard(
            transfer: t,
            mode: _CardMode.dispatched,
            productName: productNames[t.productId] ?? 'Product',
            counterpartyStore: storeNames[t.toLocationId] ?? 'a store',
            byUser: users[t.initiatedBy]?.name,
          ),
        ),
        _buildTransferHistorySection(context, ref),
      ],
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required List<StockTransferData> rows,
    required Widget Function(StockTransferData) builder,
  }) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final subtext = Theme.of(context).textTheme.bodySmall?.color;
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: context.getRFontSize(11),
              fontWeight: FontWeight.bold,
              color: subtext,
              letterSpacing: 0.4,
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          for (final t in rows) ...[
            builder(t),
            SizedBox(height: context.getRSize(8)),
          ],
        ],
      ),
    );
  }

  Widget _buildTransferHistorySection(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(storeTransferHistoryProvider(storeId));
    final products =
        ref.watch(productsWithStockProvider(null)).valueOrNull ??
            const <ProductDataWithStock>[];
    final productNames = {
      for (final p in products) p.product.id: p.product.name,
    };
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final storeNames = {for (final s in stores) s.id: s.name};

    final text = Theme.of(context).colorScheme.onSurface;
    final subtext = Theme.of(context).textTheme.bodySmall?.color;
    final border = Theme.of(context).dividerColor;
    final surface = Theme.of(context).colorScheme.surface;

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          'Transfer history',
          style: TextStyle(
            fontSize: context.getRFontSize(14),
            fontWeight: FontWeight.bold,
            color: text,
          ),
        ),
        children: [
          historyAsync.when(
            data: (transfers) {
              if (transfers.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(context.getRSize(16)),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: border),
                  ),
                  child: Text(
                    'No past transfers for this store.',
                    style: TextStyle(
                      color: subtext,
                      fontSize: context.getRFontSize(13),
                    ),
                  ),
                );
              }

              final displayedTransfers = transfers.take(30).toList();

              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: displayedTransfers.length,
                separatorBuilder: (context, index) => SizedBox(height: context.getRSize(8)),
                itemBuilder: (context, index) {
                  final t = displayedTransfers[index];
                  final productName = productNames[t.productId] ?? 'Unknown Product';
                  final isIn = t.toLocationId == storeId;
                  final counterpartyId = isIn ? t.fromLocationId : t.toLocationId;
                  final counterpartyName = storeNames[counterpartyId] ?? 'Unknown Store';
                  
                  final dateStr = DateFormat('MMM d, y • h:mm a').format(t.lastUpdatedAt);

                  return Container(
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: border),
                    ),
                    padding: EdgeInsets.all(context.getRSize(12)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '$productName · ${t.quantity} unit(s)',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: text,
                                  fontSize: context.getRFontSize(13),
                                ),
                              ),
                              SizedBox(height: context.getRSize(4)),
                              Text(
                                '${isIn ? "From" : "To"} $counterpartyName',
                                style: TextStyle(
                                  color: subtext,
                                  fontSize: context.getRFontSize(12),
                                ),
                              ),
                              SizedBox(height: context.getRSize(4)),
                              Text(
                                dateStr,
                                style: TextStyle(
                                  color: subtext,
                                  fontSize: context.getRFontSize(11),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: context.getRSize(8),
                                vertical: context.getRSize(3),
                              ),
                              decoration: BoxDecoration(
                                color: isIn
                                    ? AppColors.success.withValues(alpha: 0.1)
                                    : AppColors.info.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isIn ? 'IN' : 'OUT',
                                style: TextStyle(
                                  fontSize: context.getRFontSize(10),
                                  fontWeight: FontWeight.bold,
                                  color: isIn ? AppColors.success : AppColors.info,
                                ),
                              ),
                            ),
                            SizedBox(height: context.getRSize(6)),
                            Text(
                              t.status.toUpperCase(),
                              style: TextStyle(
                                fontSize: context.getRFontSize(10),
                                fontWeight: FontWeight.w600,
                                color: t.status == 'cancelled'
                                    ? AppColors.danger
                                    : subtext,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (err, stack) => Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Error loading history: $err',
                  style: const TextStyle(color: AppColors.danger),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _CardMode { fulfil, receive, requested, dispatched }

class _TransferActionCard extends ConsumerStatefulWidget {
  final StockTransferData transfer;
  final _CardMode mode;
  final String productName;
  final String counterpartyStore;
  final String? byUser;
  final int availableHere;
  final String? manufacturerId;
  final bool isCrateEligible;
  final int availableEmpties;

  const _TransferActionCard({
    required this.transfer,
    required this.mode,
    required this.productName,
    required this.counterpartyStore,
    this.byUser,
    this.availableHere = 0,
    this.manufacturerId,
    this.isCrateEligible = false,
    this.availableEmpties = 0,
  });

  @override
  ConsumerState<_TransferActionCard> createState() =>
      _TransferActionCardState();
}

class _TransferActionCardState extends ConsumerState<_TransferActionCard> {
  bool _busy = false;

  Future<void> _run(
    String permission,
    Future<void> Function(String userId) action,
    String successMsg,
  ) async {
    if (!ref.read(currentUserPermissionsProvider).contains(permission)) return;
    final userId = ref.read(authProvider).currentUser?.id;
    if (userId == null) return;
    setState(() => _busy = true);
    try {
      await action(userId);
      if (!mounted) return;
      AppNotification.showSuccess(context, successMsg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppNotification.showError(context, 'Could not complete that action.');
    }
  }

  Future<void> _accept() async {
    final result = await _askQuantity();
    if (result == null) return;
    final qty = result.quantity;
    final empties = result.empties;
    await _run(
      'stores.dispatch_transfer',
      (uid) => ref.read(databaseProvider).stockTransferDao.dispatchTransfer(
            transferId: widget.transfer.id,
            dispatchedBy: uid,
            quantity: qty,
            emptyCratesToSend: empties,
          ),
      empties > 0
          ? 'Dispatched $qty unit(s) + $empties empty crate(s) to ${widget.counterpartyStore}.'
          : 'Dispatched $qty unit(s) to ${widget.counterpartyStore}.',
    );
  }

  Future<void> _reject() => _run(
        'stores.dispatch_transfer',
        (uid) => ref.read(databaseProvider).stockTransferDao.rejectRequest(
              transferId: widget.transfer.id,
              rejectedBy: uid,
            ),
        'Request declined.',
      );

  Future<void> _receive() => _run(
        'stores.receive_transfer',
        (uid) => ref.read(databaseProvider).stockTransferDao.receiveTransfer(
              transferId: widget.transfer.id,
              receivedBy: uid,
            ),
        'Transfer received — stock updated.',
      );

  Future<void> _cancel() => _run(
        'stores.dispatch_transfer',
        (uid) => ref.read(databaseProvider).stockTransferDao.cancelTransfer(
              transferId: widget.transfer.id,
              cancelledBy: uid,
            ),
        'Transfer cancelled — stock restored.',
      );

  /// Accept dialog: confirm or alter the dispatched quantity and optionally send empty crates.
  Future<({int quantity, int empties})?> _askQuantity() async {
    final qtyCtrl =
        TextEditingController(text: widget.transfer.quantity.toString());
    final emptiesCtrl = TextEditingController(text: '0');
    final showEmptiesField = widget.isCrateEligible && widget.availableEmpties > 0;

    final result = await showDialog<({int quantity, int empties})>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: const Text('Dispatch quantity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Requested: ${widget.transfer.quantity}   ·   '
              'Available here: ${widget.availableHere}',
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                color: Theme.of(ctx).textTheme.bodySmall?.color,
              ),
            ),
            SizedBox(height: context.getRSize(12)),
            AppInput(
              controller: qtyCtrl,
              labelText: 'Quantity to send',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            if (showEmptiesField) ...[
              SizedBox(height: context.getRSize(12)),
              AppInput(
                controller: emptiesCtrl,
                labelText: 'Empty crates to send (optional)',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              SizedBox(height: context.getRSize(4)),
              Text(
                'Available here: ${widget.availableEmpties}',
                style: TextStyle(
                  fontSize: context.getRFontSize(11),
                  color: Theme.of(ctx).textTheme.bodySmall?.color,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final q = int.tryParse(qtyCtrl.text.trim()) ?? 0;
              if (q <= 0) {
                AppNotification.showError(ctx, 'Enter a quantity above 0.');
                return;
              }
              int empties = 0;
              if (showEmptiesField) {
                empties = int.tryParse(emptiesCtrl.text.trim()) ?? 0;
                if (empties < 0) {
                  AppNotification.showError(ctx, 'Enter a valid empty crates count.');
                  return;
                }
                if (empties > widget.availableEmpties) {
                  AppNotification.showError(
                    ctx,
                    'Cannot send more than available empties (${widget.availableEmpties}).',
                  );
                  return;
                }
              }
              Navigator.pop(ctx, (quantity: q, empties: empties));
            },
            child: const Text('Dispatch'),
          ),
        ],
      ),
    );
    qtyCtrl.dispose();
    emptiesCtrl.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final border = Theme.of(context).dividerColor;
    final text = Theme.of(context).colorScheme.onSurface;
    final subtext = Theme.of(context).textTheme.bodySmall?.color;
    final primary = Theme.of(context).colorScheme.primary;

    final canDispatch = Gates.dispatchStoreTransfer.allows(ref);
    final canReceive = Gates.receiveStoreTransfer.allows(ref);

    final subtitle = switch (widget.mode) {
      _CardMode.fulfil =>
        'Requested by ${widget.byUser ?? 'staff'} for ${widget.counterpartyStore}',
      _CardMode.receive => 'From ${widget.counterpartyStore}',
      _CardMode.requested =>
        'Requested from ${widget.counterpartyStore} — awaiting dispatch',
      _CardMode.dispatched =>
        'Dispatched to ${widget.counterpartyStore} — in transit',
    };

    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      padding: EdgeInsets.all(context.getRSize(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.productName} · ${widget.transfer.quantity} unit(s)',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: text,
                    fontSize: context.getRFontSize(14),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            subtitle,
            style: TextStyle(
              color: subtext,
              fontSize: context.getRFontSize(12),
            ),
          ),
          if (widget.mode == _CardMode.fulfil && canDispatch) ...[
            SizedBox(height: context.getRSize(12)),
            Row(
              children: [
                Expanded(
                  child: _btn(
                    label: _busy ? 'Working…' : 'Accept & Dispatch',
                    color: primary,
                    onTap: _busy ? null : _accept,
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: _btn(
                    label: 'Reject',
                    color: Theme.of(context).colorScheme.error,
                    onTap: _busy ? null : _reject,
                  ),
                ),
              ],
            ),
          ],
          if (widget.mode == _CardMode.receive && canReceive) ...[
            SizedBox(height: context.getRSize(12)),
            _btn(
              label: _busy ? 'Working…' : 'Confirm Receipt',
              color: primary,
              onTap: _busy ? null : _receive,
            ),
          ],
          if (widget.mode == _CardMode.dispatched && canDispatch) ...[
            SizedBox(height: context.getRSize(12)),
            _btn(
              label: _busy ? 'Working…' : 'Cancel Transfer',
              color: Theme.of(context).colorScheme.error,
              onTap: _busy ? null : _cancel,
            ),
          ],
        ],
      ),
    );
  }

  Widget _btn({
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      height: context.getRSize(40),
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: EdgeInsets.zero,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: context.getRFontSize(13),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
