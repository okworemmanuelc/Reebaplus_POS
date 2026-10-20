import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

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
    final productMap = {for (final p in products) p.product.id: p.product};
    final emptiesMap =
        ref.watch(storeEmptiesByManufacturerProvider(storeId)).valueOrNull ??
        const <String, int>{};
    // Deliberately UNfiltered (#140): this is a name lookup for rendering, not
    // a picker. A van can never be a transfer endpoint — `request_stock_screen`
    // drops it from both dropdowns — but if a legacy row ever names one, show
    // its real name rather than "a store". The pickers are the exclusion seam.
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final storeNames = {for (final s in stores) s.id: s.name};
    final users =
        ref.watch(usersByBusinessProvider).valueOrNull ??
        const <String, UserData>{};

    // Stock-on-hand at THIS store, for the Accept dialog's availability hint.
    final hereStock = {
      for (final p
          in ref.watch(productsByStoreProvider(storeId)).valueOrNull ??
              const <ProductDataWithStock>[])
        p.product.id: p.totalStock,
    };

    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final hasAny =
        incomingReqs.isNotEmpty ||
        incomingTransfers.isNotEmpty ||
        outgoingReqs.isNotEmpty ||
        outgoingTransfers.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Stock Transfers'),
        SizedBox(height: context.getRSize(12)),
        if (!hasAny)
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(context.getRSize(16)),
            decoration: AppDecorations.card(context),
            child: Text(
              'No active transfers for this store.',
              style: context.regularStyle(13).copyWith(color: muted),
            ),
          ),
        _section(
          context,
          title: 'Requests to fulfil',
          rows: incomingReqs,
          builder: (t) {
            final p = productMap[t.productId];
            final manufacturerId = p?.manufacturerId;
            final isCrateEligible =
                p != null &&
                p.unit?.toLowerCase() == 'bottle' &&
                p.trackEmpties;
            final availableEmpties = manufacturerId != null
                ? (emptiesMap[manufacturerId] ?? 0)
                : 0;
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
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: title.toUpperCase(),
            variant: SectionHeaderVariant.group,
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

    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;

    return StoresExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const SectionHeader(
        title: 'Transfer history',
        variant: SectionHeaderVariant.group,
      ),
      children: [
        historyAsync.when(
          data: (transfers) {
            if (transfers.isEmpty) {
              return Container(
                width: double.infinity,
                padding: EdgeInsets.all(context.getRSize(16)),
                decoration: AppDecorations.card(context),
                child: Text(
                  'No past transfers for this store.',
                  style: context.regularStyle(13).copyWith(color: muted),
                ),
              );
            }

            final displayedTransfers = transfers.take(30).toList();

            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: displayedTransfers.length,
              separatorBuilder: (context, index) =>
                  SizedBox(height: context.getRSize(8)),
              itemBuilder: (context, index) {
                final tr = displayedTransfers[index];
                final productName =
                    productNames[tr.productId] ?? 'Unknown Product';
                final isIn = tr.toLocationId == storeId;
                final counterpartyId = isIn
                    ? tr.fromLocationId
                    : tr.toLocationId;
                final counterpartyName =
                    storeNames[counterpartyId] ?? 'Unknown Store';

                final dateStr = DateFormat(
                  'MMM d, y • h:mm a',
                ).format(tr.lastUpdatedAt);

                return Container(
                  decoration: AppDecorations.card(context),
                  padding: EdgeInsets.all(context.getRSize(12)),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$productName · ${tr.quantity} unit(s)',
                              style: context
                                  .boldStyle(13)
                                  .copyWith(color: text),
                            ),
                            SizedBox(height: context.getRSize(4)),
                            Text(
                              '${isIn ? "From" : "To"} $counterpartyName',
                              style: context
                                  .regularStyle(12)
                                  .copyWith(color: muted),
                            ),
                            SizedBox(height: context.getRSize(4)),
                            Text(
                              dateStr,
                              style: context
                                  .regularStyle(11)
                                  .copyWith(color: muted),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: context.getRSize(8)),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          TagPill(
                            label: isIn ? 'IN' : 'OUT',
                            tone: isIn ? TagPillTone.green : TagPillTone.info,
                            dense: true,
                          ),
                          SizedBox(height: context.getRSize(6)),
                          Text(
                            tr.status.toUpperCase(),
                            style: context
                                .semiBoldStyle(11)
                                .copyWith(
                                  color: tr.status == 'cancelled'
                                      ? f.danger
                                      : muted,
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
                style: TextStyle(color: f.danger),
              ),
            ),
          ),
        ),
      ],
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
    NamedGate gate,
    Future<void> Function(String userId) action,
    String successMsg,
  ) async {
    if (!gate.allowsNow(ref)) {
      showGateDenied(context, gate);
      return;
    }
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
      Gates.dispatchStoreTransfer,
      (uid) => ref
          .read(databaseProvider)
          .stockTransferDao
          .dispatchTransfer(
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
    Gates.dispatchStoreTransfer,
    (uid) => ref
        .read(databaseProvider)
        .stockTransferDao
        .rejectRequest(transferId: widget.transfer.id, rejectedBy: uid),
    'Request declined.',
  );

  Future<void> _receive() => _run(
    Gates.receiveStoreTransfer,
    (uid) => ref
        .read(databaseProvider)
        .stockTransferDao
        .receiveTransfer(transferId: widget.transfer.id, receivedBy: uid),
    'Transfer received — stock updated.',
  );

  Future<void> _cancel() => _run(
    Gates.dispatchStoreTransfer,
    (uid) => ref
        .read(databaseProvider)
        .stockTransferDao
        .cancelTransfer(transferId: widget.transfer.id, cancelledBy: uid),
    'Transfer cancelled — stock restored.',
  );

  /// Accept dialog: confirm or alter the dispatched quantity and optionally send empty crates.
  Future<({int quantity, int empties})?> _askQuantity() {
    final showEmptiesField =
        widget.isCrateEligible && widget.availableEmpties > 0;
    return showDialog<({int quantity, int empties})>(
      context: context,
      builder: (_) => _DispatchDialog(
        requested: widget.transfer.quantity,
        availableHere: widget.availableHere,
        showEmptiesField: showEmptiesField,
        availableEmpties: widget.availableEmpties,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
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
    final tone = switch (widget.mode) {
      _CardMode.fulfil => IconTileTone.info,
      _CardMode.receive => IconTileTone.green,
      _CardMode.requested => IconTileTone.neutral,
      _CardMode.dispatched => IconTileTone.warning,
    };

    return Container(
      decoration: AppDecorations.card(context),
      padding: EdgeInsets.all(context.getRSize(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconTile(icon: AppIcons.transfer, tone: tone, size: 40),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.productName} · ${widget.transfer.quantity} unit(s)',
                      style: context.boldStyle(14).copyWith(color: text),
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      subtitle,
                      style: context.regularStyle(12).copyWith(color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (widget.mode == _CardMode.fulfil && canDispatch) ...[
            SizedBox(height: context.getRSize(12)),
            // Two buttons side by side while each has room for its label,
            // stacked otherwise (measured, never a viewport predicate).
            LayoutBuilder(
              builder: (context, c) {
                final accept = _btn(
                  label: _busy ? 'Working…' : 'Accept & Dispatch',
                  onTap: _busy ? null : _accept,
                );
                final reject = _btn(
                  label: 'Reject',
                  danger: true,
                  onTap: _busy ? null : _reject,
                );
                if (c.maxWidth >= context.getRSize(340)) {
                  return Row(
                    children: [
                      Expanded(child: accept),
                      SizedBox(width: context.getRSize(8)),
                      Expanded(child: reject),
                    ],
                  );
                }
                return Column(
                  children: [
                    accept,
                    SizedBox(height: context.getRSize(8)),
                    reject,
                  ],
                );
              },
            ),
          ],
          if (widget.mode == _CardMode.receive && canReceive) ...[
            SizedBox(height: context.getRSize(12)),
            _btn(
              label: _busy ? 'Working…' : 'Confirm Receipt',
              onTap: _busy ? null : _receive,
            ),
          ],
          if (widget.mode == _CardMode.dispatched && canDispatch) ...[
            SizedBox(height: context.getRSize(12)),
            _btn(
              label: _busy ? 'Working…' : 'Cancel Transfer',
              danger: true,
              onTap: _busy ? null : _cancel,
            ),
          ],
        ],
      ),
    );
  }

  Widget _btn({
    required String label,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    return AppButton(
      text: label,
      variant: danger ? AppButtonVariant.danger : AppButtonVariant.primary,
      height: kMinInteractiveDimension,
      onPressed: onTap,
    );
  }
}

/// The Accept dialog: confirm or alter the dispatched quantity and optionally
/// send empty crates. **Owns its controllers** (created and disposed in this
/// State): the caller used to dispose them the moment `showDialog` returned,
/// while the dialog was still animating out with its fields mounted, which
/// threw "A TextEditingController was used after being disposed."
class _DispatchDialog extends StatefulWidget {
  const _DispatchDialog({
    required this.requested,
    required this.availableHere,
    required this.showEmptiesField,
    required this.availableEmpties,
  });

  final int requested;
  final int availableHere;
  final bool showEmptiesField;
  final int availableEmpties;

  @override
  State<_DispatchDialog> createState() => _DispatchDialogState();
}

class _DispatchDialogState extends State<_DispatchDialog> {
  late final TextEditingController _qtyCtrl = TextEditingController(
    text: widget.requested.toString(),
  );
  final TextEditingController _emptiesCtrl = TextEditingController(text: '0');

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _emptiesCtrl.dispose();
    super.dispose();
  }

  void _submit(BuildContext ctx) {
    final q = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (q <= 0) {
      AppNotification.showError(ctx, 'Enter a quantity above 0.');
      return;
    }
    int empties = 0;
    if (widget.showEmptiesField) {
      empties = int.tryParse(_emptiesCtrl.text.trim()) ?? 0;
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
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color;
    return AlertDialog(
      scrollable: true,
      title: Text(
        'Dispatch quantity',
        style: context.screenTitleStyle.copyWith(
          color: t.colorScheme.onSurface,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Requested: ${widget.requested}   ·   '
            'Available here: ${widget.availableHere}',
            style: context.regularStyle(12).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            controller: _qtyCtrl,
            labelText: 'Quantity to send',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          if (widget.showEmptiesField) ...[
            SizedBox(height: context.getRSize(12)),
            AppInput(
              controller: _emptiesCtrl,
              labelText: 'Empty crates to send (optional)',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            SizedBox(height: context.getRSize(4)),
            Text(
              'Available here: ${widget.availableEmpties}',
              style: context.regularStyle(11).copyWith(color: muted),
            ),
          ],
        ],
      ),
      actions: [
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          size: AppButtonSize.small,
          height: kMinInteractiveDimension,
          isFullWidth: false,
          width: context.getRSize(120),
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          text: 'Dispatch',
          size: AppButtonSize.small,
          height: kMinInteractiveDimension,
          isFullWidth: false,
          width: context.getRSize(120),
          onPressed: () => _submit(context),
        ),
      ],
    );
  }
}
