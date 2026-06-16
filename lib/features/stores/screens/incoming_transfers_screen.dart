import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// Stock Transfers screen (§16.8.1).
///
/// Two tabs — Incoming (in_transit to viewer's stores; Confirm Receipt gated
/// by `stores.receive_transfer`) and Outgoing (dispatched from viewer's stores;
/// Cancel gated by `stores.manage`). A third tab shows completed/cancelled
/// history. CEO sees all stores; a store-scoped user sees only their stores'.
class IncomingTransfersScreen extends ConsumerWidget {
  const IncomingTransfersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = ref.watch(viewerScopedIncomingTransfersProvider);
    final outgoing = ref.watch(viewerScopedOutgoingTransfersProvider);
    final history =
        ref.watch(stockTransferHistoryProvider).valueOrNull ?? const [];
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final usersById =
        ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
    final storeNames = {for (final s in stores) s.id: s.name};

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: context.backgroundColor,
        appBar: AppBar(
          title: Text(
            'Stock Transfers',
            style: context.h3.copyWith(fontWeight: FontWeight.bold),
          ),
          elevation: 0,
          backgroundColor: context.backgroundColor,
          leading: BackButton(color: context.primaryColor),
          bottom: TabBar(
            labelColor: context.primaryColor,
            unselectedLabelColor: Theme.of(context).hintColor,
            indicatorColor: context.primaryColor,
            tabs: const [
              Tab(text: 'Incoming'),
              Tab(text: 'Outgoing'),
              Tab(text: 'History'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _TransferList(
              transfers: incoming,
              storeNames: storeNames,
              usersById: usersById,
              mode: _Mode.incoming,
              emptyLabel: 'No incoming transfers',
            ),
            _TransferList(
              transfers: outgoing,
              storeNames: storeNames,
              usersById: usersById,
              mode: _Mode.outgoing,
              emptyLabel: 'No outgoing transfers',
            ),
            _TransferList(
              transfers: history,
              storeNames: storeNames,
              usersById: usersById,
              mode: _Mode.history,
              emptyLabel: 'No transfer history',
            ),
          ],
        ),
      ),
    );
  }
}

enum _Mode { incoming, outgoing, history }

class _TransferList extends StatelessWidget {
  const _TransferList({
    required this.transfers,
    required this.storeNames,
    required this.usersById,
    required this.mode,
    required this.emptyLabel,
  });

  final List<StockTransferData> transfers;
  final Map<String, String> storeNames;
  final Map<String, UserData> usersById;
  final _Mode mode;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (transfers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FontAwesomeIcons.rightLeft.data,
              size: 40,
              color: Theme.of(context).hintColor,
            ),
            const SizedBox(height: 12),
            Text(
              emptyLabel,
              style: context.bodyMedium.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        context.spacingM,
        context.spacingM,
        context.spacingM,
        context.spacingM + context.deviceBottomPadding,
      ),
      itemCount: transfers.length,
      separatorBuilder: (_, __) => SizedBox(height: context.spacingS),
      itemBuilder: (_, i) => _TransferCard(
        transfer: transfers[i],
        storeNames: storeNames,
        usersById: usersById,
        mode: mode,
      ),
    );
  }
}

class _TransferCard extends ConsumerStatefulWidget {
  const _TransferCard({
    required this.transfer,
    required this.storeNames,
    required this.usersById,
    required this.mode,
  });

  final StockTransferData transfer;
  final Map<String, String> storeNames;
  final Map<String, UserData> usersById;
  final _Mode mode;

  @override
  ConsumerState<_TransferCard> createState() => _TransferCardState();
}

class _TransferCardState extends ConsumerState<_TransferCard> {
  bool _busy = false;

  Future<void> _confirm() async {
    // Layer 3 (write-boundary re-check).
    if (!ref
        .read(currentUserPermissionsProvider)
        .contains('stores.receive_transfer')) {
      return;
    }
    final userId = ref.read(authProvider).currentUser?.id;
    if (userId == null) return;

    setState(() => _busy = true);
    try {
      await ref
          .read(databaseProvider)
          .stockTransferDao
          .receiveTransfer(transferId: widget.transfer.id, receivedBy: userId);
      if (!mounted) return;
      AppNotification.showSuccess(
        context,
        'Transfer received — stock updated.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppNotification.showError(context, 'Could not confirm receipt: $e');
    }
  }

  Future<void> _cancel() async {
    // Layer 3 (write-boundary re-check).
    if (!ref.read(currentUserPermissionsProvider).contains('stores.manage')) {
      return;
    }
    final userId = ref.read(authProvider).currentUser?.id;
    if (userId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel Transfer?'),
        content: const Text('Stock will be restored to the source store.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Cancel Transfer',
              style: TextStyle(color: Colors.red.shade600),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref
          .read(databaseProvider)
          .stockTransferDao
          .cancelTransfer(transferId: widget.transfer.id, cancelledBy: userId);
      if (!mounted) return;
      AppNotification.showSuccess(
        context,
        'Transfer cancelled — stock restored.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppNotification.showError(context, 'Could not cancel: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.transfer;
    final fromName = widget.storeNames[t.fromLocationId] ?? 'Unknown store';
    final toName = widget.storeNames[t.toLocationId] ?? 'Unknown store';
    final initiatorName =
        widget.usersById[t.initiatedBy]?.name ?? 'Unknown staff';

    final canReceive = hasPermission(ref, 'stores.receive_transfer');
    final canManage = hasPermission(ref, 'stores.manage');

    // Status badge colour.
    final statusColor = switch (t.status) {
      'received' => Colors.green.shade600,
      'cancelled' => Colors.red.shade600,
      _ => Theme.of(context).colorScheme.primary,
    };

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: statusColor.withValues(alpha: 0.25)),
      ),
      padding: EdgeInsets.all(context.spacingM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$fromName → $toName',
                  style: context.h3.copyWith(fontSize: rFontSize(context, 15)),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  t.status.replaceAll('_', ' '),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: rFontSize(context, 11),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: context.spacingS),
          Text(
            'Qty: ${t.quantity}   ·   By: $initiatorName',
            style: context.bodyMedium.copyWith(
              color: Theme.of(context).hintColor,
              fontSize: rFontSize(context, 12),
            ),
          ),
          if (t.status == 'in_transit') ...[
            SizedBox(height: context.spacingM),
            Row(
              children: [
                if (widget.mode == _Mode.incoming && canReceive)
                  Expanded(
                    child: _ActionButton(
                      label: _busy ? 'Confirming…' : 'Confirm Receipt',
                      color: Colors.green.shade600,
                      onPressed: _busy ? null : _confirm,
                    ),
                  ),
                if (widget.mode == _Mode.incoming && canReceive && canManage)
                  SizedBox(width: context.spacingS),
                if (canManage)
                  Expanded(
                    child: _ActionButton(
                      label: _busy ? 'Cancelling…' : 'Cancel Transfer',
                      color: Colors.red.shade600,
                      onPressed: _busy ? null : _cancel,
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

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: EdgeInsets.zero,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: rFontSize(context, 13),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
