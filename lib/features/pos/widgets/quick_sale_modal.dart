import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/shared/widgets/sales_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/shared/utils/product_icon_helper.dart';

/// Quick Sale modal (master plan §12.3). For a CEO/Manager it adds straight to
/// the cart. For a role below Manager ([requireApproval] true, §12.3.1) "Send
/// for Approval" records a pending request instead — the modal then shows a
/// "Waiting for approval…" state and watches the request. When a Manager/CEO
/// approves (the status flip arrives via sync) the item drops into the cart;
/// on rejection the modal closes with a "Quick sale was rejected" message.
class QuickSaleModal extends ConsumerStatefulWidget {
  // The five colour arguments are kept for the POS call site (#393); the
  // dialog now reads every colour from the theme.
  final Color surfaceCol;
  final Color textCol;
  final Color subtextCol;
  final Color cardCol;
  final bool isDark;

  /// When true the actor is below Manager: route through the approval queue
  /// (§12.3.1) rather than adding straight to the cart.
  final bool requireApproval;

  const QuickSaleModal({
    super.key,
    required this.surfaceCol,
    required this.textCol,
    required this.subtextCol,
    required this.cardCol,
    required this.isDark,
    this.requireApproval = false,
  });

  @override
  ConsumerState<QuickSaleModal> createState() => _QuickSaleModalState();
}

class _QuickSaleModalState extends ConsumerState<QuickSaleModal>
    with SingleTickerProviderStateMixin {
  final _nameCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();

  // Approval flow (§12.3.1) state.
  bool _submitting = false; // creating the request
  String? _requestId; // non-null = waiting-for-approval phase
  bool _resolved = false; // approved/rejected/withdrawn handled once
  StreamSubscription<QuickSaleRequestData?>? _statusSub;
  // The entered values, captured at submit so the approved item can be added
  // to the cart from the original (canonical) request row.
  String _pendingName = '';
  double _pendingQty = 1.0;
  double _pendingPriceNaira = 0.0;

  // Created lazily the first time the "Awaiting Approval" state renders (the
  // only place it's used) via [_pulseAnim]. Kept nullable — never a `late
  // final` with an inline initializer — so dispose() can't trigger the
  // initializer for a modal that closed without ever entering the waiting
  // state (the common CEO/Manager direct-add path). Building an
  // AnimationController does a TickerMode ancestor lookup, which throws
  // "Looking up a deactivated widget's ancestor is unsafe" when run during the
  // element's unmount.
  AnimationController? _pulse;
  AnimationController get _pulseAnim => _pulse ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _statusSub?.cancel();
    _pulse?.dispose();
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  bool get _fieldsFilled =>
      _nameCtrl.text.isNotEmpty &&
      _qtyCtrl.text.isNotEmpty &&
      _priceCtrl.text.isNotEmpty;

  Map<String, dynamic> _buildProduct(String name, double priceNaira) =>
      buildQuickSaleProduct(name, priceNaira);

  // Direct add (CEO/Manager): unchanged behaviour.
  void _addToCart() {
    if (!_fieldsFilled) {
      AppNotification.showError(
        context,
        'Item Name, Quantity, and Price are required.',
      );
      return;
    }
    final priceNaira = parseCurrency(_priceCtrl.text);
    ref
        .read(cartProvider)
        .addItem(
          _buildProduct(_nameCtrl.text, priceNaira),
          qty: double.tryParse(_qtyCtrl.text) ?? 1.0,
        );
    Navigator.pop(context);
  }

  /// The active selling store the request is scoped to (for approver routing) —
  /// the §12.1 picked/locked store, falling back to the user's first assigned
  /// store. Null only if the user has no store at all.
  String? _resolveActiveStoreId() {
    final locked = ref.read(lockedStoreProvider).value;
    if (locked != null && locked.isNotEmpty) return locked;
    final uid = ref.read(authProvider).currentUser?.id;
    if (uid == null) return null;
    final myStores = ref.read(myUserStoresProvider(uid)).valueOrNull;
    if (myStores != null && myStores.isNotEmpty) return myStores.first.storeId;
    return null;
  }

  // Below-Manager submit (§12.3.1): record a pending request, then wait.
  Future<void> _sendForApproval() async {
    if (!_fieldsFilled) {
      AppNotification.showError(
        context,
        'Item Name, Quantity, and Price are required.',
      );
      return;
    }
    final storeId = _resolveActiveStoreId();
    if (storeId == null) {
      AppNotification.showError(
        context,
        'Pick your store before making a Quick Sale.',
      );
      return;
    }
    final name = _nameCtrl.text.trim();
    final qty = double.tryParse(_qtyCtrl.text) ?? 1.0;
    final priceNaira = parseCurrency(_priceCtrl.text);
    final qtyLabel = qty == qty.roundToDouble()
        ? qty.toInt().toString()
        : qty.toString();
    final summary =
        '$qtyLabel × $name @ ${formatCurrency(priceNaira)} '
        '= ${formatCurrency(qty * priceNaira)}';
    final uid = ref.read(authProvider).currentUser?.id;

    setState(() => _submitting = true);
    final db = ref.read(databaseProvider);
    try {
      final id = await db.quickSaleRequestsDao.requestQuickSale(
        storeId: storeId,
        itemName: name,
        quantity: qty,
        unitPriceKobo: (priceNaira * 100).round(),
        summary: summary,
        requestedBy: uid,
      );
      if (!mounted) return;
      setState(() {
        _pendingName = name;
        _pendingQty = qty;
        _pendingPriceNaira = priceNaira;
        _requestId = id;
        _submitting = false;
      });
      _statusSub = db.quickSaleRequestsDao
          .watchRequest(id)
          .listen(_onStatusChange);
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'pos.quick_sale.request');
      if (!mounted) return;
      setState(() => _submitting = false);
      AppNotification.showError(context, 'Could not send for approval: $e');
    }
  }

  void _onStatusChange(QuickSaleRequestData? r) {
    if (r == null || _resolved) return;
    if (r.status == 'approved') {
      _resolved = true;
      if (!mounted) return;
      ref
          .read(cartProvider)
          .addItem(
            _buildProduct(_pendingName, _pendingPriceNaira),
            qty: _pendingQty,
          );
      AppNotification.showSuccess(
        context,
        'Quick sale approved — added to cart.',
      );
      Navigator.pop(context);
    } else if (r.status == 'rejected') {
      _resolved = true;
      if (!mounted) return;
      AppNotification.showError(context, 'Quick sale was rejected.');
      Navigator.pop(context);
    }
  }

  // Cashier withdrew the request (Cancel / back) while still pending.
  Future<void> _withdrawAndClose() async {
    if (_resolved) {
      if (mounted) Navigator.pop(context);
      return;
    }
    _resolved = true;
    final id = _requestId;
    if (id != null) {
      await ref
          .read(databaseProvider)
          .quickSaleRequestsDao
          .cancelRequest(requestId: id);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _requestId != null;
    return PopScope(
      // Block the bare back-pop while waiting so we can withdraw the request
      // first; the input phase pops normally.
      canPop: !waiting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && waiting) _withdrawAndClose();
      },
      child: Dialog(
        key: QuickSaleKeys.dialog,
        insetPadding: EdgeInsets.all(context.getRSize(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kQuickSaleMaxWidth),
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(20)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(
                      icon: waiting ? AppIcons.pending : AppIcons.quickSale,
                      tone: IconTileTone.warning,
                      size: 44,
                    ),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      child: Text(
                        waiting ? 'Awaiting Approval' : 'Quick Sale ⚡',
                        style: context.screenTitleStyle.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: context.getRSize(20)),
                Flexible(child: waiting ? _buildWaiting() : _buildForm()),
                SizedBox(height: context.getRSize(20)),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: context.getRSize(8),
                  runSpacing: context.getRSize(8),
                  children: waiting ? _waitingActions() : _formActions(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    // Scrolls so the three fields + actions never overflow the dialog when the
    // keyboard shrinks the available height on small screens.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppInput(
            controller: _nameCtrl,
            labelText: 'Item Name',
            prefixIcon: Icon(AppIcons.tag, size: context.getRSize(18)),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            controller: _qtyCtrl,
            labelText: 'Quantity',
            prefixIcon: Icon(AppIcons.crates, size: context.getRSize(18)),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter(grouping: false)],
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            controller: _priceCtrl,
            labelText: 'Price Per Unit ($activeCurrencySymbol)',
            hintText: 'e.g. 500',
            prefixIcon: Icon(AppIcons.naira, size: context.getRSize(18)),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
          if (widget.requireApproval) ...[
            SizedBox(height: context.getRSize(12)),
            const SalesNotice(
              key: QuickSaleKeys.approvalNote,
              tone: SalesNoticeTone.info,
              message:
                  'A Manager or CEO must approve this before it reaches the cart.',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWaiting() {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Fade-pulse, not a rotating spinner (coding rule #6).
        FadeTransition(
          opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_pulseAnim),
          child: const IconTile(icon: AppIcons.pending, size: 56),
        ),
        SizedBox(height: context.getRSize(16)),
        Text(
          'Waiting for approval…',
          style: context.boldStyle(15).copyWith(color: t.colorScheme.onSurface),
        ),
        SizedBox(height: context.getRSize(6)),
        Text(
          'A Manager or CEO is reviewing this Quick Sale. It will be added to '
          'your cart once approved.',
          textAlign: TextAlign.center,
          style: context.regularStyle(12).copyWith(color: muted),
        ),
        SizedBox(height: context.getRSize(14)),
        Container(
          padding: EdgeInsets.all(context.getRSize(12)),
          decoration: AppDecorations.card(
            context,
            radius: AppSpacing.borderRadiusM,
          ),
          child: Row(
            children: [
              AppIcon(
                AppIcons.quickSale,
                filled: true,
                size: context.getRSize(18),
                color: t.colorScheme.primary,
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: Text(
                  '${_pendingQty == _pendingQty.roundToDouble() ? _pendingQty.toInt() : _pendingQty} × '
                  '$_pendingName · ${formatCurrency(_pendingQty * _pendingPriceNaira)}',
                  style: context
                      .semiBoldStyle(13)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _formActions() => [
    AppButton(
      text: 'Cancel',
      variant: AppButtonVariant.ghost,
      isFullWidth: false,
      onPressed: _submitting ? null : () => Navigator.pop(context),
    ),
    AppButton(
      text: widget.requireApproval ? 'Send for Approval' : 'Send to Cart',
      variant: AppButtonVariant.primary,
      isFullWidth: false,
      isLoading: _submitting,
      onPressed: widget.requireApproval ? _sendForApproval : _addToCart,
    ),
  ];

  List<Widget> _waitingActions() => [
    AppButton(
      text: 'Cancel Request',
      variant: AppButtonVariant.outline,
      isFullWidth: false,
      onPressed: _withdrawAndClose,
    ),
  ];
}

/// The Quick Sale dialog's width cap on tablets and wide screens (#393).
const double kQuickSaleMaxWidth = 560;

/// Keys the Quick Sale tests find the parts by (#393).
abstract final class QuickSaleKeys {
  static const dialog = Key('quick-sale-dialog');
  static const approvalNote = Key('quick-sale-approval-note');
}

/// Keep every value JSON-serializable: a Quick Sale line lands in the cart and
/// a held cart is persisted via `jsonEncode` (§13.5). Store the bolt as its int
/// codepoint (mirrors a real product's `iconCodePoint`; resolved back by
/// [productIconFromCodePoint]) and leave `color` null — the cart/checkout
/// readers fall back to the theme primary for a null colour, so the look is
/// unchanged. A raw `IconData`/`Color` here would throw on `jsonEncode`.
@visibleForTesting
Map<String, dynamic> buildQuickSaleProduct(String name, double priceNaira) => {
  'name': name,
  'subtitle': 'Quick Sale',
  'price': priceNaira,
  'icon': kStoredIconBolt,
  'color': null,
  'category': 'Other',
};
