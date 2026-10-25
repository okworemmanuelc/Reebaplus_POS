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

  Future<void> _accept(OnlineOrderData order) => _run(() async {
    final dao = ref.read(databaseProvider).onlineOrdersDao;
    var outcome = await dao.accept(onlineOrderId: order.id);
    if (outcome == OnlineOrderAnswerOutcome.needsCustomerChoice) {
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
      outcome = await dao.accept(onlineOrderId: order.id, link: choice);
    }
    _report(outcome, 'Order accepted');
  }, 'orders.online.accept');

  Future<void> _decline(OnlineOrderData order) => _run(() async {
    final reason = await showDeclineReasonDialog(context);
    if (reason == null) return;
    final outcome = await ref
        .read(databaseProvider)
        .onlineOrdersDao
        .decline(onlineOrderId: order.id, reason: reason);
    _report(outcome, 'Order declined');
  }, 'orders.online.decline');

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
    required this.onAccept,
    required this.onDecline,
  });

  final OnlineOrderData order;
  final bool busy;
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
    final note = onlineOrderStatusNote(order);
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
                for (final l in lines) OnlineOrderLineRow(line: l),
                OnlineOrderTotalRow(totalKobo: order.estimatedTotalKobo),
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
                      onPressed: busy ? null : onAccept,
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}
