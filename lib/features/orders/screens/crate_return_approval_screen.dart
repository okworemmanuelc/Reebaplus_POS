import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';

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
    } catch (e) {
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
    } catch (e) {
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
        title: const Text('Reject Crate Return'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Reason for rejection',
            hintText: 'e.g. Incorrect quantity',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pendingAsync = ref.watch(pendingReturnsWithDetailsProvider);
    final surface = Theme.of(context).colorScheme.surface;
    final text = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: surface,
      appBar: AppBar(
        backgroundColor: surface,
        elevation: 0,
        title: Text(
          'Crate Return Approval',
          style: TextStyle(
            color: text,
            fontWeight: FontWeight.bold,
            fontSize: context.getRFontSize(17),
          ),
        ),
      ),
      body: AppRefreshWrapper(
        child: pendingAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, s) => Center(child: Text('Error: $e')),
          data: (returns) {
            if (returns.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FontAwesomeIcons.circleCheck,
                        color: Colors.green.withValues(alpha: 0.5),
                        size: context.getRSize(48)),
                    const SizedBox(height: 16),
                    Text(
                      'No pending returns',
                      style: TextStyle(
                        color: text,
                        fontWeight: FontWeight.bold,
                        fontSize: context.getRFontSize(15),
                      ),
                    ),
                  ],
                ),
              );
            }

            // Group by submission (customerId + approximate submittedAt)
            final Map<String, List<PendingReturnWithDetails>> groups = {};
            for (final r in returns) {
              final timeKey =
                  DateFormat('yyyy-MM-dd HH:mm').format(r.returnRow.submittedAt);
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

            return ListView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + context.bottomInset,
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
    final text = Theme.of(context).colorScheme.onSurface;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        first.customer.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Text(
                      DateFormat('MMM d, h:mm a').format(first.returnRow.submittedAt),
                      style: TextStyle(
                        color: text.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                if (first.returnRow.orderId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Order: ${first.returnRow.orderId!.substring(0, 8)}...',
                      style: TextStyle(
                        color: text.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...batch.map((item) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(FontAwesomeIcons.box,
                          size: 14, color: Colors.orange),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.crateGroup.name,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          Text(
                            'Quantity: ${item.returnRow.quantity}',
                            style: TextStyle(
                              color: text.withValues(alpha: 0.6),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(FontAwesomeIcons.xmark,
                              color: Colors.red, size: 18),
                          onPressed: processing ? null : () => onReject(item.returnRow.id),
                        ),
                        IconButton(
                          icon: const Icon(FontAwesomeIcons.check,
                              color: Colors.green, size: 18),
                          onPressed: processing ? null : () => onApprove(item.returnRow.id),
                        ),
                      ],
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
