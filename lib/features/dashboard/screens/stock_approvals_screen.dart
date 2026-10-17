import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
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
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

const kStockApprovalCardKeyPrefix = 'approval-card-';
const kQuickSaleApprovalCardKeyPrefix = 'quick-sale-approval-card-';
const kCrateDepositApprovalCardKeyPrefix = 'crate-deposit-approval-card-';

Key stockApprovalCardKey(String id) => Key('$kStockApprovalCardKeyPrefix$id');
Key quickSaleApprovalCardKey(String id) =>
    Key('$kQuickSaleApprovalCardKeyPrefix$id');
Key crateDepositApprovalCardKey(String id) =>
    Key('$kCrateDepositApprovalCardKeyPrefix$id');

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
      for (final p
          in ref.watch(productsWithStockProvider(null)).valueOrNull ??
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

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: SharedScaffold(
        activeRoute: 'dashboard',
        backgroundColor: Colors.transparent,
        appBar: ReportTopBar(
          key: ReportKeys.topBar,
          height: reportTopBarHeight(context),
          header: ScreenHeader(
            leading: const ReportBackButton(),
            icon: AppIcons.clipboardList,
            title: 'Approvals',
            subtitle: ref.watch(activeStoreLabelProvider),
          ),
        ),
        body: cards.isEmpty
            ? const ReportEmpty(
                icon: AppIcons.auditCheck,
                message: 'No pending approvals',
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final gutter = reportGutter(context, constraints.maxWidth);
                  return ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      gutter,
                      context.getRSize(16),
                      gutter,
                      context.getRSize(16) + context.deviceBottomPadding,
                    ),
                    itemCount: cards.length,
                    separatorBuilder: (_, __) =>
                        SizedBox(height: context.getRSize(12)),
                    itemBuilder: (_, i) => cards[i],
                  );
                },
              ),
      ),
    );
  }
}

AppFixedColors _fixed(BuildContext context) =>
    Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;

/// The fixed colours of one approval card: tile fill, ink (icon, quantity and
/// amount). Colour mapping (no new colours): amber -> warning, blue -> info,
/// teal -> info, indigo -> purple, red -> danger, green -> green.
typedef _Accent = (Color tint, Color ink);

/// The shared frame of the three approval cards (#413 PR 3): a flat card
/// (surface fill, hairline, soft shadow) holding an [ExpansionTile] with an
/// [IconTile], the title, a PENDING [TagPill] + time, and the quantity /
/// amount on the right. The keyed [Material] stays the card (its colour,
/// shape and clip are pinned by `stock_approvals_screen_test.dart`).
class _ApprovalShell extends StatelessWidget {
  const _ApprovalShell({
    required this.cardKey,
    required this.accent,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.children,
  });

  final Key cardKey;
  final _Accent accent;
  final IconData icon;
  final String title;
  final String subtitle;
  final String trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final shadow =
        t.extension<AppSchemeColors>()?.cardShadow ??
        Colors.black.withValues(alpha: 0.05);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(color: shadow, blurRadius: 12, offset: const Offset(0, 2)),
        ],
      ),
      child: Material(
        key: cardKey,
        color: context.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: t.dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          // Strip the default ExpansionTile dividers so it reads as one card.
          data: t.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.symmetric(
              horizontal: context.getRSize(14),
              vertical: context.getRSize(4),
            ),
            childrenPadding: EdgeInsets.fromLTRB(
              context.getRSize(14),
              0,
              context.getRSize(14),
              context.getRSize(14),
            ),
            leading: IconTile(
              icon: icon,
              tint: accent.$1,
              iconColor: accent.$2,
              size: 40,
            ),
            title: Text(
              title,
              style: context
                  .boldStyle(15)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
            subtitle: Padding(
              padding: EdgeInsets.only(top: context.getRSize(4)),
              child: Row(
                children: [
                  const TagPill(
                    label: 'PENDING',
                    tone: TagPillTone.warning,
                    dense: true,
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Flexible(
                    child: Text(
                      subtitle,
                      overflow: TextOverflow.ellipsis,
                      style: context.regularStyle(12).copyWith(color: muted),
                    ),
                  ),
                ],
              ),
            ),
            trailing: Text(
              trailing,
              style: context.extraBoldStyle(16).copyWith(color: accent.$2),
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// A "label | value" line inside an expanded approval card.
class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: context.getRSize(96),
            child: Text(
              label,
              style: context.regularStyle(13).copyWith(color: muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: context
                  .mediumStyle(13)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

/// The busy spinner that replaces the Reject / Approve row while a decision
/// is being written.
class _BusyRow extends StatelessWidget {
  const _BusyRow();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(8),
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}

/// Reject (outline) + the positive action (success), side by side.
class _DecisionRow extends StatelessWidget {
  const _DecisionRow({
    required this.positiveText,
    required this.onReject,
    required this.onPositive,
  });

  final String positiveText;
  final VoidCallback onReject;
  final VoidCallback onPositive;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: AppButton(
          text: 'Reject',
          variant: AppButtonVariant.outline,
          onPressed: onReject,
        ),
      ),
      SizedBox(width: context.getRSize(12)),
      Expanded(
        child: AppButton(
          text: positiveText,
          variant: AppButtonVariant.success,
          onPressed: onPositive,
        ),
      ),
    ],
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

  _Accent get _accent {
    final f = _fixed(context);
    return widget.request.quantityDiff < 0
        ? (f.dangerTint, f.danger)
        : (f.greenTint, f.green);
  }

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

    return _ApprovalShell(
      cardKey: stockApprovalCardKey(r.id),
      accent: _accent,
      icon: isRemove ? AppIcons.arrowDown : AppIcons.arrowUp,
      title: r.summary,
      subtitle: _timeAgo(r.createdAt),
      trailing: qtyLabel,
      children: [
        _DetailRow('Requested by', widget.requesterName),
        _DetailRow('Store', widget.storeName),
        _DetailRow('Reason', r.reason),
        // #197 (PRD #155 US 22): what the goods cost, so the approver sees
        // the money they are letting in — and can reject a wrong price
        // instead of discovering it as a wrong profit figure later. Shown on
        // an INCREASE only: a removal is valued by drawing the store's FIFO
        // queue at approval time, not by the requester.
        if (!isRemove) ...[
          _DetailRow('Cost per unit', _unitCostLabel),
          if (totalCostLabel != null) _DetailRow('Total cost', totalCostLabel),
        ],
        _DetailRow('When', _fullStamp(r.createdAt)),
        SizedBox(height: context.getRSize(16)),
        if (_busy)
          const _BusyRow()
        else
          _DecisionRow(
            positiveText: 'Approve',
            onReject: () => _decide(approve: false),
            onPositive: () => _decide(approve: true),
          ),
      ],
    );
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

  _Accent get _accent {
    final f = _fixed(context);
    return (f.infoTint, f.info);
  }

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

    return _ApprovalShell(
      cardKey: quickSaleApprovalCardKey(r.id),
      accent: _accent,
      icon: AppIcons.quickSale,
      title: r.itemName,
      subtitle: 'Quick Sale · ${_timeAgo(r.createdAt)}',
      trailing: formatCurrency(totalNaira),
      children: [
        _DetailRow('Requested by', widget.requesterName),
        _DetailRow('Store', widget.storeName),
        _DetailRow('Item', r.itemName),
        _DetailRow('Quantity', qtyLabel),
        _DetailRow('Unit price', formatCurrency(r.unitPriceKobo / 100.0)),
        _DetailRow('Total', formatCurrency(totalNaira)),
        _DetailRow('When', _fullStamp(r.createdAt)),
        SizedBox(height: context.getRSize(16)),
        if (_busy)
          const _BusyRow()
        else
          _DecisionRow(
            positiveText: 'Approve',
            onReject: () => _decide(approve: false),
            onPositive: () => _decide(approve: true),
          ),
      ],
    );
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

  _Accent get _accent {
    final f = _fixed(context);
    return _isRefund ? (f.infoTint, f.info) : (f.purpleTint, f.purple);
  }

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
          _isRefund && (amountKobo ?? 0) < widget.request.requestedAmountKobo;
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
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return _ApprovalShell(
      cardKey: crateDepositApprovalCardKey(r.id),
      accent: _accent,
      icon: AppIcons.transfer,
      title: '${_isRefund ? 'Crate refund' : 'Crate deposit'} — ${r.summary}',
      subtitle: _timeAgo(r.createdAt),
      trailing: formatCurrency(r.requestedAmountKobo / 100),
      children: [
        _DetailRow('Recorded by', widget.requesterName),
        _DetailRow('Store', widget.storeName),
        _DetailRow('Crates', '${r.crateCount}'),
        _DetailRow('Rate per crate', formatCurrency(r.ratePerCrateKobo / 100)),
        _DetailRow('When', _fullStamp(r.createdAt)),
        SizedBox(height: context.getRSize(8)),
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
          style: context.regularStyle(13).copyWith(color: muted),
        ),
        SizedBox(height: context.getRSize(8)),
        AppInput(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          labelText: _isRefund ? 'Amount refunded' : 'Amount paid',
          prefixText: '$activeCurrencySymbol ',
        ),
        SizedBox(height: context.getRSize(16)),
        if (_busy)
          const _BusyRow()
        else
          _DecisionRow(
            positiveText: 'Confirm',
            onReject: () => _decide(confirm: false),
            onPositive: () => _decide(confirm: true),
          ),
      ],
    );
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
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return AlertDialog(
      scrollable: true,
      backgroundColor: context.surfaceColor,
      title: Text(
        'Reject request',
        style: context.boldStyle(18).copyWith(color: t.colorScheme.onSurface),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Optionally tell the ${widget.subject} why their request was rejected.',
            style: context.regularStyle(13).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            key: const Key('approval-reject-reason'),
            controller: _ctrl,
            autofocus: true,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            hintText: 'Reason (optional)',
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
