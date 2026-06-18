import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';

/// Quick Sale modal (master plan §12.3). For a CEO/Manager it adds straight to
/// the cart. For a role below Manager ([requireApproval] true, §12.3.1) "Send
/// for Approval" records a pending request instead — the modal then shows a
/// "Waiting for approval…" state and watches the request. When a Manager/CEO
/// approves (the status flip arrives via sync) the item drops into the cart;
/// on rejection the modal closes with a "Quick sale was rejected" message.
class QuickSaleModal extends ConsumerStatefulWidget {
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

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _statusSub?.cancel();
    _pulse.dispose();
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  bool get _fieldsFilled =>
      _nameCtrl.text.isNotEmpty &&
      _qtyCtrl.text.isNotEmpty &&
      _priceCtrl.text.isNotEmpty;

  Map<String, dynamic> _buildProduct(String name, double priceNaira) => {
    'name': name,
    'subtitle': 'Quick Sale',
    'price': priceNaira,
    'icon': FontAwesomeIcons.bolt,
    'color': Theme.of(context).colorScheme.primary,
    'category': 'Other',
  };

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
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: EdgeInsets.all(context.getRSize(20)),
        child: GlassyCard(
          radius: 24.0,
          padding: EdgeInsets.all(context.getRSize(24)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                waiting ? 'Awaiting Approval' : 'Quick Sale ⚡',
                style: TextStyle(
                  color: widget.textCol,
                  fontWeight: FontWeight.bold,
                  fontSize: context.getRFontSize(20),
                ),
              ),
              SizedBox(height: context.getRSize(24)),
              Flexible(child: waiting ? _buildWaiting() : _buildForm()),
              SizedBox(height: context.getRSize(24)),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: (waiting ? _waitingActions() : _formActions())
                    .map((w) => Padding(
                          padding: EdgeInsets.only(left: context.getRSize(8)),
                          child: w,
                        ))
                    .toList(),
              ),
            ],
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
        children: [
          AppInput(
            controller: _nameCtrl,
            labelText: 'Item Name',
            prefixIcon: Icon(
              FontAwesomeIcons.tag.data,
              size: context.getRSize(16),
            ),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            controller: _qtyCtrl,
            labelText: 'Quantity',
            prefixIcon: Icon(
              FontAwesomeIcons.cubes.data,
              size: context.getRSize(16),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter(grouping: false)],
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            controller: _priceCtrl,
            labelText: 'Price Per Unit ($activeCurrencySymbol)',
            hintText: 'e.g. 500',
            prefixIcon: Icon(
              FontAwesomeIcons.nairaSign.data,
              size: context.getRSize(16),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
          if (widget.requireApproval) ...[
            SizedBox(height: context.getRSize(12)),
            Row(
              children: [
                Icon(
                  FontAwesomeIcons.circleInfo.data,
                  size: context.getRSize(13),
                  color: widget.subtextCol,
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: Text(
                    'A Manager or CEO must approve this before it reaches the cart.',
                    style: TextStyle(
                      color: widget.subtextCol,
                      fontSize: context.getRFontSize(12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWaiting() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Fade-pulse, not a rotating spinner (coding rule #6).
        FadeTransition(
          opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_pulse),
          child: Icon(
            FontAwesomeIcons.hourglassHalf.data,
            size: context.getRSize(34),
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        SizedBox(height: context.getRSize(16)),
        Text(
          'Waiting for approval…',
          style: TextStyle(
            color: widget.textCol,
            fontWeight: FontWeight.w700,
            fontSize: context.getRFontSize(15),
          ),
        ),
        SizedBox(height: context.getRSize(6)),
        Text(
          'A Manager or CEO is reviewing this Quick Sale. It will be added to '
          'your cart once approved.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: widget.subtextCol,
            fontSize: context.getRFontSize(12),
          ),
        ),
        SizedBox(height: context.getRSize(14)),
        Container(
          padding: EdgeInsets.all(context.getRSize(12)),
          decoration: BoxDecoration(
            color: widget.cardCol,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                FontAwesomeIcons.bolt.data,
                size: context.getRSize(14),
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: Text(
                  '${_pendingQty == _pendingQty.roundToDouble() ? _pendingQty.toInt() : _pendingQty} × '
                  '$_pendingName · ${formatCurrency(_pendingQty * _pendingPriceNaira)}',
                  style: TextStyle(
                    color: widget.textCol,
                    fontWeight: FontWeight.w600,
                    fontSize: context.getRFontSize(12),
                  ),
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
