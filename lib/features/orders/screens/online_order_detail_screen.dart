import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/online_orders/online_order_answer.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/online_order_providers.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_order_dialogs.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_order_parts.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// One Online Order (#427): who, where, the lines and estimated total, and —
/// while it is `new` and the viewer may answer for its store — Accept and
/// Decline. Answering writes through Drift + the outbox (OnlineOrdersDao).
class OnlineOrderDetailScreen extends ConsumerStatefulWidget {
  const OnlineOrderDetailScreen({super.key, required this.onlineOrderId});

  final String onlineOrderId;

  @override
  ConsumerState<OnlineOrderDetailScreen> createState() =>
      _OnlineOrderDetailScreenState();
}

class _OnlineOrderDetailScreenState
    extends ConsumerState<OnlineOrderDetailScreen> {
  bool _busy = false;

  /// Quantities staff chose before accepting (line id -> qty); lines not here
  /// are untouched (#428). Lowering only: the row's controls never go above
  /// what was asked, and the DAO rejects a raise.
  final Map<String, int> _qty = {};

  Future<void> _run(Future<void> Function() action, String where) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e, st) {
      CrashReporter.record(e, st, context: where);
      if (mounted) {
        AppNotification.showError(context, 'Could not save. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _report(OnlineOrderAnswerOutcome outcome, String done) {
    if (!mounted) return;
    switch (outcome) {
      case OnlineOrderAnswerOutcome.answered:
        AppNotification.showSuccess(context, done);
      case OnlineOrderAnswerOutcome.alreadyAnswered:
        AppNotification.showError(context, 'This order was already answered.');
      case OnlineOrderAnswerOutcome.needsCustomerChoice:
        break;
    }
  }

  /// Accept: a Shopper's first order here asks staff to choose the Customer
  /// (the pop-up opens with no spinner behind it; only writes show busy).
  Future<void> _accept(OnlineOrderData order) async {
    if (_busy) return;
    final dao = ref.read(databaseProvider).onlineOrdersDao;
    OnlineOrderAnswerOutcome? outcome;
    await _run(() async {
      outcome = await dao.accept(
        onlineOrderId: order.id,
        acceptedQtys: Map.of(_qty),
      );
    }, 'orders.online.accept');
    if (outcome != OnlineOrderAnswerOutcome.needsCustomerChoice) {
      if (outcome != null) _report(outcome!, 'Order accepted');
      return;
    }
    final suggestions = await dao.suggestCustomers(
      phone: order.deliveryPhone,
      name: order.shopperName,
    );
    if (!mounted) return;
    final choice = await showLinkCustomerDialog(
      context,
      shopperName: order.shopperName,
      suggestions: suggestions,
      search: dao.searchLinkableCustomers,
    );
    if (choice == null) return;
    await _run(() async {
      final linked = await dao.accept(
        onlineOrderId: order.id,
        link: choice,
        acceptedQtys: Map.of(_qty),
      );
      _report(linked, 'Order accepted');
    }, 'orders.online.accept');
  }

  Future<void> _decline(OnlineOrderData order) async {
    if (_busy) return;
    final reason = await showDeclineReasonDialog(context);
    if (reason == null) return;
    await _run(() async {
      final outcome = await ref
          .read(databaseProvider)
          .onlineOrdersDao
          .decline(onlineOrderId: order.id, reason: reason);
      _report(outcome, 'Order declined');
    }, 'orders.online.decline');
  }

  Future<void> _cancelAccepted(OnlineOrderData order) async {
    if (_busy) return;
    final reason = await showCancelAcceptedDialog(context);
    if (reason == null) return;
    await _run(() async {
      final outcome = await ref
          .read(databaseProvider)
          .onlineOrdersDao
          .cancelAccepted(onlineOrderId: order.id, reason: reason);
      _report(outcome, 'Order cancelled');
    }, 'orders.online.cancelAccepted');
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(onlineOrderProvider(widget.onlineOrderId));
    return Scaffold(
      appBar: OrdersTopBar(
        height: ordersTopBarHeight(context),
        icon: AppIcons.public,
        title: 'Online order',
        subtitle: order.valueOrNull?.reference,
        leading: Navigator.of(context).canPop()
            ? OrdersBackButton(onPressed: () => Navigator.of(context).pop())
            : null,
      ),
      body: DecoratedBox(
        decoration: AppDecorations.pageBackground(context),
        child: order.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (o) => o == null
              ? const Center(
                  child: OrdersEmptyState(
                    icon: AppIcons.public,
                    text: 'This order is no longer here',
                  ),
                )
              : _OnlineOrderBody(
                  order: o,
                  busy: _busy,
                  quantities: _qty,
                  onQuantity: (id, q) => setState(() => _qty[id] = q),
                  onCancelAccepted: () => _cancelAccepted(o),
                  onAccept: () => _accept(o),
                  onDecline: () => _decline(o),
                ),
        ),
      ),
    );
  }
}

class _OnlineOrderBody extends ConsumerWidget {
  const _OnlineOrderBody({
    required this.order,
    required this.busy,
    required this.quantities,
    required this.onQuantity,
    required this.onCancelAccepted,
    required this.onAccept,
    required this.onDecline,
  });

  final OnlineOrderData order;
  final bool busy;
  final Map<String, int> quantities;
  final void Function(String lineId, int qty) onQuantity;
  final VoidCallback onCancelAccepted;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines =
        ref.watch(onlineOrderLinesProvider(order.id)).valueOrNull ?? const [];
    final customerId = order.customerId;
    final customer = customerId == null
        ? null
        : ref.watch(onlineOrderCustomerProvider(customerId)).valueOrNull;
    final canAnswer =
        order.status == 'new' &&
        ref.watch(canAnswerOnlineOrderProvider(order.storeId));
    final canCancel =
        order.status == 'accepted' &&
        ref.watch(canAnswerOnlineOrderProvider(order.storeId));
    final prices = canAnswer
        ? ref.watch(onlineOrderRetailPricesProvider(order.id)).valueOrNull
        : null;
    final note = onlineOrderStatusNote(order);
    final allRemoved =
        lines.isNotEmpty &&
        lines.every((l) => (quantities[l.id] ?? l.requestedQty) == 0);
    final shownTotal = canAnswer
        ? lines.fold<int>(
            0,
            (sum, l) =>
                sum + l.unitPriceKobo * (quantities[l.id] ?? l.requestedQty),
          )
        : lines.isEmpty
        ? order.estimatedTotalKobo
        : lines.fold<int>(
            0,
            (sum, l) =>
                sum + l.unitPriceKobo * (l.acceptedQty ?? l.requestedQty),
          );
    final placed = DateFormat('d MMM yyyy, h:mm a').format(order.placedAt);
    final orderNote = order.note;

    return LayoutBuilder(
      builder: (context, constraints) {
        final side = ordersCapPadding(
          constraints.maxWidth,
          context.getRSize(16),
        );
        return ListView(
          padding: EdgeInsets.fromLTRB(
            side,
            context.getRSize(16),
            side,
            context.getRSize(16) + context.deviceBottomPadding,
          ),
          children: [
            OnlineOrderSection(
              title: 'Status',
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: OnlineOrderStatusPill(status: order.status),
                ),
                if (note != null)
                  OnlineOrderInfoRow(icon: AppIcons.infoCircle, text: note),
                OnlineOrderInfoRow(
                  icon: AppIcons.history,
                  text: 'Placed $placed',
                ),
              ],
            ),
            OnlineOrderSection(
              title: 'Customer',
              children: [
                OnlineOrderInfoRow(
                  icon: AppIcons.user,
                  text: order.shopperName,
                ),
                OnlineOrderInfoRow(
                  icon: AppIcons.phone,
                  text: order.deliveryPhone,
                ),
                OnlineOrderInfoRow(
                  icon: AppIcons.location,
                  text: onlineOrderAddress(order),
                ),
                if (orderNote != null && orderNote.trim().isNotEmpty)
                  OnlineOrderInfoRow(
                    icon: AppIcons.description,
                    text: orderNote,
                  ),
                if (customer != null)
                  OnlineOrderInfoRow(
                    icon: AppIcons.customers,
                    text: 'Your customer: ${customer.name}',
                  ),
              ],
            ),
            OnlineOrderSection(
              title: 'Items',
              children: [
                for (final l in lines)
                  if (canAnswer)
                    OnlineOrderEditableLineRow(
                      line: l,
                      quantity: quantities[l.id] ?? l.requestedQty,
                      currentPriceKobo: prices?[l.productId],
                      onChanged: (q) => onQuantity(l.id, q),
                    )
                  else
                    OnlineOrderLineRow(line: l),
                OnlineOrderTotalRow(totalKobo: shownTotal),
              ],
            ),
            if (canAnswer)
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      key: OnlineOrderKeys.decline,
                      text: 'Decline',
                      variant: AppButtonVariant.outline,
                      onPressed: busy ? null : onDecline,
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: AppButton(
                      key: OnlineOrderKeys.accept,
                      text: 'Accept',
                      isLoading: busy,
                      onPressed: busy || allRemoved ? null : onAccept,
                    ),
                  ),
                ],
              ),
            if (canCancel)
              AppButton(
                key: OnlineOrderKeys.cancelOrder,
                text: 'Cancel order',
                variant: AppButtonVariant.danger,
                onPressed: busy ? null : onCancelAccepted,
              ),
          ],
        );
      },
    );
  }
}
