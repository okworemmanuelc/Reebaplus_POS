import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Pending Stock Approvals (master plan §16.6.1). Lists the stock-keeper
/// adjustment requests the current viewer may approve — a CEO sees every store,
/// a Manager only their assigned store(s) (scoping in
/// [viewerScopedPendingStockRequestsProvider]). Each request is a tappable card
/// that expands to the full detail and Approve / Reject actions. Approving
/// applies the real inventory change; rejecting discards it. Both notify the
/// stock keeper who submitted.
class StockApprovalsScreen extends ConsumerWidget {
  const StockApprovalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(viewerScopedPendingStockRequestsProvider);
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final usersById =
        ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
    final storeNames = {for (final s in stores) s.id: s.name};

    return Scaffold(
      backgroundColor: context.backgroundColor,
      appBar: AppBar(
        title: Text(
          'Stock Approvals',
          style: context.h3.copyWith(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
      ),
      body: requests.isEmpty
          ? _EmptyState()
          : ListView.separated(
              padding: EdgeInsets.fromLTRB(
                context.spacingM,
                context.spacingM,
                context.spacingM,
                context.spacingM + context.deviceBottomInset,
              ),
              itemCount: requests.length,
              separatorBuilder: (_, __) => SizedBox(height: context.spacingS),
              itemBuilder: (_, i) {
                final r = requests[i];
                return _ApprovalCard(
                  request: r,
                  storeName: storeNames[r.storeId] ?? 'Unknown store',
                  requesterName:
                      usersById[r.requestedBy]?.name ?? 'A stock keeper',
                );
              },
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FontAwesomeIcons.clipboardCheck,
            size: 40,
            color: Theme.of(context).hintColor,
          ),
          const SizedBox(height: 12),
          Text(
            'No pending approvals',
            style: context.bodyMedium.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalCard extends ConsumerStatefulWidget {
  const _ApprovalCard({
    required this.request,
    required this.storeName,
    required this.requesterName,
  });

  final StockAdjustmentRequestData request;
  final String storeName;
  final String requesterName;

  @override
  ConsumerState<_ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends ConsumerState<_ApprovalCard> {
  bool _busy = false;

  Color get _accent =>
      widget.request.quantityDiff < 0 ? Colors.red.shade600 : Colors.green.shade600;

  Future<void> _decide({required bool approve}) async {
    final approverId = ref.read(authProvider).currentUser?.id;
    if (approverId == null) return;

    // Rejecting: ask for an optional reason first. A null result means the
    // approver cancelled — leave the request pending. An empty string means
    // reject with no reason (the DAO omits it from the notice + log).
    String? reason;
    if (!approve) {
      final result = await showDialog<String?>(
        context: context,
        builder: (_) => const _RejectReasonDialog(),
      );
      if (!mounted || result == null) return;
      reason = result;
    }

    setState(() => _busy = true);
    final dao = ref.read(databaseProvider).stockAdjustmentRequestsDao;
    try {
      if (approve) {
        await dao.approveRequest(
          requestId: widget.request.id,
          approverId: approverId,
        );
      } else {
        await dao.rejectRequest(
          requestId: widget.request.id,
          approverId: approverId,
          reason: reason,
        );
      }
      if (!mounted) return;
      // The card disappears as the request leaves the pending stream; the
      // toast confirms which way it went.
      AppNotification.showSuccess(
        context,
        approve ? 'Approved — stock updated.' : 'Request rejected.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppNotification.showError(
        context,
        approve
            ? 'Could not approve: ${_friendly(e)}'
            : 'Could not reject: $e',
      );
    }
  }

  // Surface the common "not enough stock to remove" case in plain English.
  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('InsufficientStock') || s.contains('insufficient_stock')) {
      return 'not enough stock in this store to remove that amount.';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final isRemove = r.quantityDiff < 0;
    final qtyLabel = '${isRemove ? '−' : '+'}${r.quantityDiff.abs()}';

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: _accent.withValues(alpha: 0.25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Strip the default ExpansionTile dividers so it reads as one card.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.symmetric(
            horizontal: context.spacingM,
            vertical: context.spacingXs,
          ),
          childrenPadding: EdgeInsets.fromLTRB(
            context.spacingM,
            0,
            context.spacingM,
            context.spacingM,
          ),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isRemove ? Icons.arrow_downward : Icons.arrow_upward,
              color: _accent,
              size: 20,
            ),
          ),
          title: Text(
            r.summary,
            style: context.bodyMedium.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                _pendingChip(context),
                const SizedBox(width: 8),
                Text(
                  _timeAgo(r.createdAt),
                  style: context.bodySmall.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
          trailing: Text(
            qtyLabel,
            style: context.bodyLarge.copyWith(
              fontWeight: FontWeight.w800,
              color: _accent,
            ),
          ),
          children: [
            _detailRow(context, 'Requested by', widget.requesterName),
            _detailRow(context, 'Store', widget.storeName),
            _detailRow(context, 'Reason', r.reason),
            _detailRow(context, 'When', _fullStamp(r.createdAt)),
            SizedBox(height: context.spacingM),
            if (_busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      text: 'Reject',
                      variant: AppButtonVariant.outline,
                      onPressed: () => _decide(approve: false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppButton(
                      text: 'Approve',
                      variant: AppButtonVariant.success,
                      onPressed: () => _decide(approve: true),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _pendingChip(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'PENDING',
        style: context.bodySmall.copyWith(
          fontSize: context.getRFontSize(10),
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: Colors.amber.shade800,
        ),
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: context.getRSize(96),
            child: Text(
              label,
              style: context.bodySmall.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: context.bodySmall.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return _fullStamp(dt);
  }

  String _fullStamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// Asks the approver for an optional reason before rejecting a stock request.
/// Owns its own `TextEditingController` and disposes it in `dispose()` (never
/// after an `await`) — the controller-lifecycle rule from the Update Stock
/// crash fix. Pops the typed reason on Reject (may be empty), `null` on Cancel.
class _RejectReasonDialog extends StatefulWidget {
  const _RejectReasonDialog();

  @override
  State<_RejectReasonDialog> createState() => _RejectReasonDialogState();
}

class _RejectReasonDialogState extends State<_RejectReasonDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      title: Text(
        'Reject request',
        style: context.h3.copyWith(fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Optionally tell the stock keeper why their request was rejected.',
            style: context.bodySmall.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Reason (optional)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
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
          onPressed: () => Navigator.pop(context, _ctrl.text),
        ),
      ],
    );
  }
}
