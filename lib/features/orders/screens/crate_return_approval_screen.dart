import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

class CrateReturnApprovalScreen extends ConsumerStatefulWidget {
  final String? pendingReturnId;
  final String? notificationId;

  const CrateReturnApprovalScreen({
    super.key,
    this.pendingReturnId,
    this.notificationId,
  });

  @override
  ConsumerState<CrateReturnApprovalScreen> createState() =>
      _CrateReturnApprovalScreenState();
}

class _CrateReturnApprovalScreenState
    extends ConsumerState<CrateReturnApprovalScreen> {
  bool _processing = false;

  Future<void> _approve(String id) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      final user = ref.read(authProvider).currentUser;
      if (user == null) throw Exception('Not authenticated');

      await ref.read(crateReturnApprovalServiceProvider).approve(id, user.id);
      if (mounted) AppNotification.showSuccess(context, 'Return approved');
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'orders.crate_return.approve');
      if (mounted) AppNotification.showError(context, e.toString());
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _reject(String id) async {
    if (_processing) return;
    final reason = await _showRejectionDialog();
    if (reason == null) return;

    setState(() => _processing = true);
    try {
      final user = ref.read(authProvider).currentUser;
      if (user == null) throw Exception('Not authenticated');

      await ref
          .read(crateReturnApprovalServiceProvider)
          .reject(id, user.id, reason);
      if (mounted) AppNotification.showSuccess(context, 'Return rejected');
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'orders.crate_return.reject');
      if (mounted) AppNotification.showError(context, e.toString());
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<String?> _showRejectionDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Reject Crate Return',
          style: context.screenTitleStyle.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        content: AppInput(
          key: const Key('crate-return-reject-reason'),
          controller: controller,
          labelText: 'Reason for rejection',
          hintText: 'e.g. Incorrect quantity',
          autofocus: true,
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(context),
          ),
          AppButton(
            text: 'Reject',
            variant: AppButtonVariant.danger,
            isFullWidth: false,
            onPressed: () => Navigator.pop(context, controller.text),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pendingAsync = ref.watch(pendingReturnsWithDetailsProvider);

    return Scaffold(
      appBar: OrdersTopBar(
        key: const Key('crate-return-approval-top-bar'),
        height: ordersTopBarHeight(context),
        icon: AppIcons.crates,
        title: 'Crate Return Approval',
        leading: Navigator.of(context).canPop()
            ? OrdersBackButton(onPressed: () => Navigator.of(context).pop())
            : null,
      ),
      body: DecoratedBox(
        decoration: AppDecorations.pageBackground(context),
        child: AppRefreshWrapper(
          child: pendingAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, s) => Center(child: Text('Error: $e')),
            data: (returns) {
              if (returns.isEmpty) {
                return const Center(
                  child: OrdersEmptyState(
                    icon: AppIcons.checkCircle,
                    text: 'No pending returns',
                  ),
                );
              }

              // Group by submission (customerId + approximate submittedAt)
              final Map<String, List<PendingReturnWithDetails>> groups = {};
              for (final r in returns) {
                final timeKey = DateFormat(
                  'yyyy-MM-dd HH:mm',
                ).format(r.returnRow.submittedAt);
                final key = '${r.returnRow.customerId}_$timeKey';
                groups.putIfAbsent(key, () => []);
                groups[key]!.add(r);
              }

              final sortedKeys = groups.keys.toList()
                ..sort((a, b) {
                  final aTime = groups[a]!.first.returnRow.submittedAt;
                  final bTime = groups[b]!.first.returnRow.submittedAt;
                  return bTime.compareTo(aTime); // Latest first
                });

              return LayoutBuilder(
                builder: (context, constraints) {
                  final side = ordersCapPadding(
                    constraints.maxWidth,
                    context.getRSize(16),
                  );
                  return ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                      side,
                      context.getRSize(16),
                      side,
                      context.getRSize(16) + context.deviceBottomPadding,
                    ),
                    itemCount: sortedKeys.length,
                    itemBuilder: (context, index) {
                      final group = groups[sortedKeys[index]]!;
                      return _SubmissionBatchTile(
                        batch: group,
                        onApprove: _approve,
                        onReject: _reject,
                        processing: _processing,
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SubmissionBatchTile extends StatelessWidget {
  final List<PendingReturnWithDetails> batch;
  final Function(String) onApprove;
  final Function(String) onReject;
  final bool processing;

  const _SubmissionBatchTile({
    required this.batch,
    required this.onApprove,
    required this.onReject,
    required this.processing,
  });

  @override
  Widget build(BuildContext context) {
    final first = batch.first;
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final text = t.colorScheme.onSurface;
    final muted = t.textTheme.bodySmall?.color ?? text;

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusL,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(context.getRSize(12)),
            child: Row(
              children: [
                const IconTile(icon: AppIcons.user, size: 40),
                SizedBox(width: context.getRSize(10)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        first.customer.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.boldStyle(15).copyWith(color: text),
                      ),
                      if (first.returnRow.orderId != null)
                        Text(
                          'Order: ${first.returnRow.orderId!.substring(0, 8)}...',
                          style: context.monoStyle.copyWith(color: muted),
                        ),
                    ],
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Text(
                  DateFormat(
                    'MMM d, h:mm a',
                  ).format(first.returnRow.submittedAt),
                  style: context.regularStyle(12).copyWith(color: muted),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: t.dividerColor),
          ...batch.map(
            (item) => Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(12),
                vertical: context.getRSize(8),
              ),
              child: Row(
                children: [
                  const IconTile(
                    icon: AppIcons.box,
                    tone: IconTileTone.warning,
                    size: 40,
                  ),
                  SizedBox(width: context.getRSize(10)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.manufacturer.name,
                          style: context
                              .semiBoldStyle(14)
                              .copyWith(color: text),
                        ),
                        Text(
                          'Quantity: ${item.returnRow.quantity}',
                          style: context
                              .regularStyle(13)
                              .copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  IconButton(
                    key: Key('crate-return-reject-${item.returnRow.id}'),
                    tooltip: 'Reject',
                    constraints: const BoxConstraints(
                      minWidth: kMinInteractiveDimension,
                      minHeight: kMinInteractiveDimension,
                    ),
                    style: IconButton.styleFrom(backgroundColor: f.dangerTint),
                    icon: AppIcon(
                      AppIcons.close,
                      color: f.danger,
                      size: context.getRSize(20),
                    ),
                    onPressed: processing
                        ? null
                        : () => onReject(item.returnRow.id),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  IconButton(
                    key: Key('crate-return-approve-${item.returnRow.id}'),
                    tooltip: 'Approve',
                    constraints: const BoxConstraints(
                      minWidth: kMinInteractiveDimension,
                      minHeight: kMinInteractiveDimension,
                    ),
                    style: IconButton.styleFrom(backgroundColor: f.greenTint),
                    icon: AppIcon(
                      AppIcons.check,
                      color: f.green,
                      size: context.getRSize(20),
                    ),
                    onPressed: processing
                        ? null
                        : () => onApprove(item.returnRow.id),
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
