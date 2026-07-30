import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Pending Approvals (master plan §25.2). Lists, for the current viewer, both
/// cashier Quick Sale requests (§12.3.1) and stock-keeper adjustment requests
/// (§16.6.1) — a CEO sees every store, a Manager only their assigned store(s)
/// (scoping in the two viewer-scoped providers). Each request is a tappable card
/// that expands to the full detail and Approve / Reject actions. Approving a
/// stock change applies the real inventory change; approving a Quick Sale
/// releases the item into the cashier's cart. Both notify the requester.
class StockApprovalsScreen extends ConsumerWidget {
  const StockApprovalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stockRequests = ref.watch(viewerScopedPendingStockRequestsProvider);
    final quickRequests = ref.watch(
      viewerScopedPendingQuickSaleRequestsProvider,
    );
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final usersById =
        ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
    final storeNames = {for (final s in stores) s.id: s.name};
    // #197: what each product has on file as its buying price. A request that
    // stated no cost is approved at THIS number (#189), so the card has to know
    // it — including when it is 0, which is the one case where the approval
    // mints an Uncosted batch and US 22's promise quietly fails.
    final recordedCostByProduct = {
      for (final p in ref.watch(productsWithStockProvider(null)).valueOrNull ??
          const <ProductDataWithStock>[])
        p.product.id: p.product.buyingPriceKobo,
    };

    // #212: crate deposits only reach this list for a brand whose Crate Money
    // Arrangement is `per_delivery`, and only for a viewer who may decide money
    // (`Gates.confirmCrateDeposit`). Every brand defaults to `none`, so on a
    // business that has not deliberately switched one on this list is empty and
    // the screen renders exactly as it did before PRD #203.
    final crateDeposits = Gates.confirmCrateDeposit.allows(ref)
        ? ref.watch(viewerScopedPendingCrateDepositsProvider)
        : const <SupplierCrateDepositRequestData>[];
    // One unified list: Quick Sale requests first (a cashier is actively
    // waiting on these), then crate deposits (a supplier's driver may be
    // standing there), then stock-adjustment requests.
    final cards = <Widget>[
      for (final q in quickRequests)
        _QuickSaleApprovalCard(
          request: q,
          storeName: storeNames[q.storeId] ?? 'Unknown store',
          requesterName: usersById[q.requestedBy]?.name ?? 'A cashier',
        ),
      for (final d in crateDeposits)
        _CrateDepositApprovalCard(
          request: d,
          storeName: storeNames[d.storeId] ?? 'Unknown store',
          requesterName: usersById[d.requestedBy]?.name ?? 'A stock keeper',
        ),
      for (final r in stockRequests)
        _ApprovalCard(
          request: r,
          storeName: storeNames[r.storeId] ?? 'Unknown store',
          requesterName: usersById[r.requestedBy]?.name ?? 'A stock keeper',
          recordedCostKobo: recordedCostByProduct[r.productId] ?? 0,
        ),
    ];

    return Scaffold(
      backgroundColor: context.backgroundColor,
      appBar: AppBar(
        title: Text(
          'Approvals',
          style: context.h3.copyWith(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
      ),
      body: cards.isEmpty
          ? _EmptyState()
          : ListView.separated(
              padding: EdgeInsets.fromLTRB(
                context.spacingM,
                context.spacingM,
                context.spacingM,
                context.spacingM + context.deviceBottomPadding,
              ),
              itemCount: cards.length,
              separatorBuilder: (_, __) => SizedBox(height: context.spacingS),
              itemBuilder: (_, i) => cards[i],
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
            FontAwesomeIcons.clipboardCheck.data,
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
    required this.recordedCostKobo,
  });

  final StockAdjustmentRequestData request;
  final String storeName;
  final String requesterName;

  /// The product's buying price on file (#189) — what an approval falls back to
  /// when [request] states no cost of its own. 0 means nothing is on file, and
  /// the approval would mint an Uncosted batch.
  final int recordedCostKobo;

  @override
  ConsumerState<_ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends ConsumerState<_ApprovalCard> {
  bool _busy = false;

  Color get _accent => widget.request.quantityDiff < 0
      ? Colors.red.shade600
      : Colors.green.shade600;

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
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'inventory.stock_approval.decide');
      if (!mounted) return;
      setState(() => _busy = false);
      AppNotification.showError(
        context,
        approve ? 'Could not approve: ${_friendly(e)}' : 'Could not reject: $e',
      );
    }
  }

  /// The cost the request captured (#197). The "not stated" wording is not a
  /// formatting nicety — it names what the approval will do instead, which is
  /// the one case where the figures the approver later reads are an inference
  /// rather than an invoice. It has to distinguish the two fallbacks: the
  /// product's recorded price (#189) when there is one, and NO cost at all when
  /// there is not — the latter being exactly the 0-COGS failure US 22 exists to
  /// stop, so it must not be reported as if a price were on file.
  String get _unitCostLabel {
    final kobo = widget.request.unitCostKobo;
    if (kobo != null) return formatCurrency(kobo / 100.0);
    final recorded = widget.recordedCostKobo;
    if (recorded > 0) {
      return 'Not stated — will use the recorded '
          '${formatCurrency(recorded / 100.0)}';
    }
    return 'Not stated, and no price is on file — these units will carry '
        'no cost';
  }

  /// What the whole delivery comes to — the figure the approver is actually
  /// signing off. Null when no cost was stated (there is nothing to total).
  String? get _totalCostLabel {
    final kobo = widget.request.unitCostKobo;
    if (kobo == null) return null;
    return formatCurrency(kobo * widget.request.quantityDiff / 100.0);
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
    final totalCostLabel = _totalCostLabel;

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
            // #197 (PRD #155 US 22): what the goods cost, so the approver sees
            // the money they are letting in — and can reject a wrong price
            // instead of discovering it as a wrong profit figure later. Shown on
            // an INCREASE only: a removal is valued by drawing the store's FIFO
            // queue at approval time, not by the requester.
            if (!isRemove) ...[
              _detailRow(context, 'Cost per unit', _unitCostLabel),
              if (totalCostLabel != null)
                _detailRow(context, 'Total cost', totalCostLabel),
            ],
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

/// A pending cashier Quick Sale request (§12.3.1). Mirrors [_ApprovalCard] but
/// approving moves NO stock — it flips the request to `approved`, which (via
/// sync) releases the item into the waiting cashier's cart on their till.
class _QuickSaleApprovalCard extends ConsumerStatefulWidget {
  const _QuickSaleApprovalCard({
    required this.request,
    required this.storeName,
    required this.requesterName,
  });

  final QuickSaleRequestData request;
  final String storeName;
  final String requesterName;

  @override
  ConsumerState<_QuickSaleApprovalCard> createState() =>
      _QuickSaleApprovalCardState();
}

class _QuickSaleApprovalCardState
    extends ConsumerState<_QuickSaleApprovalCard> {
  bool _busy = false;

  Color get _accent => Colors.blue.shade600;

  Future<void> _decide({required bool approve}) async {
    final approverId = ref.read(authProvider).currentUser?.id;
    if (approverId == null) return;

    String? reason;
    if (!approve) {
      final result = await showDialog<String?>(
        context: context,
        builder: (_) => const _RejectReasonDialog(subject: 'cashier'),
      );
      if (!mounted || result == null) return;
      reason = result;
    }

    setState(() => _busy = true);
    final dao = ref.read(databaseProvider).quickSaleRequestsDao;
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
        approve ? 'Approved — sent to the cashier.' : 'Quick Sale rejected.',
      );
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'orders.quick_sale_approval.decide');
      if (!mounted) return;
      setState(() => _busy = false);
      AppNotification.showError(
        context,
        approve ? 'Could not approve: $e' : 'Could not reject: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final qty = r.quantity;
    final qtyLabel = qty == qty.roundToDouble()
        ? qty.toInt().toString()
        : qty.toString();
    final totalNaira = qty * r.unitPriceKobo / 100.0;

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: _accent.withValues(alpha: 0.25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
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
            child: Icon(FontAwesomeIcons.bolt.data, color: _accent, size: 18),
          ),
          title: Text(
            r.itemName,
            style: context.bodyMedium.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                _pendingChip(context),
                const SizedBox(width: 8),
                Text(
                  'Quick Sale · ${_timeAgo(r.createdAt)}',
                  style: context.bodySmall.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
          trailing: Text(
            formatCurrency(totalNaira),
            style: context.bodyLarge.copyWith(
              fontWeight: FontWeight.w800,
              color: _accent,
            ),
          ),
          children: [
            _detailRow(context, 'Requested by', widget.requesterName),
            _detailRow(context, 'Store', widget.storeName),
            _detailRow(context, 'Item', r.itemName),
            _detailRow(context, 'Quantity', qtyLabel),
            _detailRow(
              context,
              'Unit price',
              formatCurrency(r.unitPriceKobo / 100.0),
            ),
            _detailRow(context, 'Total', formatCurrency(totalNaira)),
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

/// A pending **crate deposit** money leg (#212, PRD #203 / ADR 0023 rule 6).
///
/// The crates on this delivery are already recorded — a stock keeper's say-so
/// is enough for a crate count and never enough for cash. What waits here is
/// only the money: confirm it, adjust the amount first (a part payment, a
/// waived deposit), or reject it. **Rejecting leaves the crate counts exactly
/// as they are**; the card says so, because an approver who thinks rejecting
/// undoes the delivery will reject the wrong things.
class _CrateDepositApprovalCard extends ConsumerStatefulWidget {
  const _CrateDepositApprovalCard({
    required this.request,
    required this.storeName,
    required this.requesterName,
  });

  final SupplierCrateDepositRequestData request;
  final String storeName;
  final String requesterName;

  @override
  ConsumerState<_CrateDepositApprovalCard> createState() =>
      _CrateDepositApprovalCardState();
}

class _CrateDepositApprovalCardState
    extends ConsumerState<_CrateDepositApprovalCard> {
  bool _busy = false;
  late final TextEditingController _amountCtrl = TextEditingController(
    text: (widget.request.requestedAmountKobo / 100).toStringAsFixed(2),
  );

  /// #213 — the same queue carries money going OUT to a supplier and money
  /// coming BACK from one, and an approver who cannot tell which is which at a
  /// glance will confirm cash in the wrong direction. Every label, the accent
  /// and the confirmation text all turn on this one flag.
  bool get _isRefund => !crateDepositMovementIsOutward(widget.request.kind);

  Color get _accent =>
      _isRefund ? Colors.teal.shade500 : Colors.indigo.shade400;

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  /// The typed amount in kobo, or null when it cannot be read as money. Parsed
  /// off the naira text the approver sees, then rounded — a deposit is typed in
  /// naira and stored in kobo, and the app never shows a hardcoded symbol.
  int? get _typedAmountKobo {
    final raw = _amountCtrl.text.trim().replaceAll(',', '');
    if (raw.isEmpty) return null;
    final naira = double.tryParse(raw);
    if (naira == null || naira < 0) return null;
    return (naira * 100).round();
  }

  Future<void> _decide({required bool confirm}) async {
    final deciderId = ref.read(authProvider).currentUser?.id;
    if (deciderId == null) return;

    int? amountKobo;
    String? reason;
    if (confirm) {
      amountKobo = _typedAmountKobo;
      if (amountKobo == null) {
        AppNotification.showError(
          context,
          _isRefund
              ? 'Enter the amount the supplier actually refunded.'
              : 'Enter the amount you paid.',
        );
        return;
      }
    } else {
      final result = await showDialog<String?>(
        context: context,
        builder: (_) => const _RejectReasonDialog(subject: 'stock keeper'),
      );
      if (!mounted || result == null) return;
      reason = result;
    }

    setState(() => _busy = true);
    final dao = ref.read(databaseProvider).cratePoolDao;
    try {
      if (confirm) {
        await dao.confirmCrateDepositRequest(
          requestId: widget.request.id,
          decidedBy: deciderId,
          amountKobo: amountKobo,
        );
      } else {
        await dao.rejectCrateDepositRequest(
          requestId: widget.request.id,
          decidedBy: deciderId,
          reason: reason,
        );
      }
      if (!mounted) return;
      final short =
          _isRefund &&
          (amountKobo ?? 0) < widget.request.requestedAmountKobo;
      AppNotification.showSuccess(
        context,
        confirm
            ? (_isRefund
                  ? (short
                        ? 'Refund recorded. The rest is still yours — it stays '
                              'as money this supplier holds.'
                        : 'Refund recorded — the money is back and this '
                              'supplier holds that much less of yours.')
                  : 'Deposit confirmed — recorded as money held by the '
                        'supplier.')
            : (_isRefund
                  ? 'Refund rejected. The crates you handed back are unchanged.'
                  : 'Deposit rejected. The crates on this delivery are '
                        'unchanged.'),
      );
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'crates.deposit_approval.decide');
      if (!mounted) return;
      setState(() => _busy = false);
      AppNotification.showError(
        context,
        confirm ? 'Could not confirm: $e' : 'Could not reject: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: _accent.withValues(alpha: 0.25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
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
              FontAwesomeIcons.moneyBillTransfer.data,
              color: _accent,
              size: 18,
            ),
          ),
          title: Text(
            '${_isRefund ? 'Crate refund' : 'Crate deposit'} — ${r.summary}',
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
            formatCurrency(r.requestedAmountKobo / 100),
            style: context.bodyLarge.copyWith(
              fontWeight: FontWeight.w800,
              color: _accent,
            ),
          ),
          children: [
            _detailRow(context, 'Recorded by', widget.requesterName),
            _detailRow(context, 'Store', widget.storeName),
            _detailRow(context, 'Crates', '${r.crateCount}'),
            _detailRow(
              context,
              'Rate per crate',
              formatCurrency(r.ratePerCrateKobo / 100),
            ),
            _detailRow(context, 'When', _fullStamp(r.createdAt)),
            SizedBox(height: context.spacingS),
            Text(
              _isRefund
                  ? 'The empties are already recorded. This is only the money '
                        '— enter what the supplier ACTUALLY handed back, even '
                        'if it is less than the deposit. Anything short of it '
                        'stays yours, still held by them.'
                  : 'The crates are already recorded. This is only the money — '
                        'change the amount if you paid something different, or '
                        'reject it if no deposit changed hands. Either way the '
                        'crate count stays as it is.',
              style: context.bodySmall.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
            SizedBox(height: context.spacingS),
            TextField(
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: _isRefund ? 'Amount refunded' : 'Amount paid',
                prefixText: '$activeCurrencySymbol ',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
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
                      onPressed: () => _decide(confirm: false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppButton(
                      text: 'Confirm',
                      variant: AppButtonVariant.success,
                      onPressed: () => _decide(confirm: true),
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

/// Asks the approver for an optional reason before rejecting a request.
/// Owns its own `TextEditingController` and disposes it in `dispose()` (never
/// after an `await`) — the controller-lifecycle rule from the Update Stock
/// crash fix. Pops the typed reason on Reject (may be empty), `null` on Cancel.
/// [subject] names the requester in the prompt ("stock keeper" / "cashier").
class _RejectReasonDialog extends StatefulWidget {
  const _RejectReasonDialog({this.subject = 'stock keeper'});

  final String subject;

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
            'Optionally tell the ${widget.subject} why their request was rejected.',
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
