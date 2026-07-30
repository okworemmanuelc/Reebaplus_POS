import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Write off a shortage or a damage — the deliberate, audited escape hatch
/// (#145, van-sales spec §5.5).
///
/// **Shortage and damage are driver-liable by DEFAULT.** Nothing on the
/// reconcile screen forgives anything automatically; a manager has to come
/// here, type an amount and give a reason. That is the whole design: a
/// write-off is a decision somebody made, and the ledger records who and why.
///
/// The sheet only ever writes the **driver-side leg, at load price** — the debt
/// being forgiven. The company loss is at the snapshotted COST and is already
/// booked (damage when the return was recorded, shortage when close clears the
/// van), and it surfaces on the close artifact as a disclosure. Forgiving at
/// load price and losing at cost is the whole point of §5.5: the business lost
/// the goods, not the margin it never earned.
class VanWriteOffSheet extends ConsumerStatefulWidget {
  final VanTripData trip;
  final String driverName;

  /// [kDriverLedgerTypeShortageWriteoff] or [kDriverLedgerTypeDamageWriteoff].
  final String type;

  /// What the driver is currently liable for in this bucket, at load price —
  /// the amount the "Forgive it all" shortcut fills in.
  final int owedKobo;

  const VanWriteOffSheet({
    super.key,
    required this.trip,
    required this.driverName,
    required this.type,
    required this.owedKobo,
  });

  static Future<void> show(
    BuildContext context, {
    required VanTripData trip,
    required String driverName,
    required String type,
    required int owedKobo,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VanWriteOffSheet(
        trip: trip,
        driverName: driverName,
        type: type,
        owedKobo: owedKobo,
      ),
    );
  }

  @override
  ConsumerState<VanWriteOffSheet> createState() => _VanWriteOffSheetState();
}

class _VanWriteOffSheetState extends ConsumerState<VanWriteOffSheet> {
  final _amountCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  bool get _isShortage => widget.type == kDriverLedgerTypeShortageWriteoff;

  String get _title => _isShortage ? 'Write off shortage' : 'Write off damage';

  @override
  void initState() {
    super.initState();
    if (widget.owedKobo > 0) {
      _amountCtrl.text = (widget.owedKobo / 100).toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false) || _saving) return;

    // Write-boundary re-check (ADR 0002 layer 3): a revocation while the form
    // is open must block the write, not merely hide the button.
    if (!Gates.vanManage.allowsNow(ref)) {
      showGateDenied(context, Gates.vanManage);
      return;
    }

    final amountKobo = (parseCurrency(_amountCtrl.text) * 100).round();
    if (amountKobo <= 0) {
      AppNotification.showError(context, 'Enter an amount greater than 0.');
      return;
    }
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null) {
      AppNotification.showError(
        context,
        'Cannot record yet — your account is still loading. Try again in a '
        'moment.',
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await ref
          .read(databaseProvider)
          .vanTripsDao
          .postWriteOff(
            tripId: widget.trip.id,
            type: widget.type,
            amountKobo: amountKobo,
            performedBy: staffId,
            reason: _reasonCtrl.text.trim().isEmpty
                ? null
                : _reasonCtrl.text.trim(),
          );
      if (!mounted) return;
      Navigator.pop(context);
      AppNotification.showSuccess(
        context,
        '${formatCurrency(amountKobo / 100)} written off for '
        '${widget.driverName}.',
      );
    } on VanTripNotOpenException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppNotification.showError(context, e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppNotification.showError(context, 'Could not record the write-off.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context),
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.45,
        maxChildSize: 0.7,
        snap: true,
        snapSizes: const [0.45, 0.7],
        builder: (context, scrollController) {
          return GestureDetector(
            onTap: () {},
            child: Container(
              decoration: BoxDecoration(
                color: t.colorScheme.surface,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(context.getRSize(28)),
                ),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.getRSize(20),
                        context.getRSize(12),
                        context.getRSize(20),
                        0,
                      ),
                      child: Column(
                        children: [
                          Center(
                            child: Container(
                              width: context.getRSize(40),
                              height: context.getRSize(4),
                              decoration: BoxDecoration(
                                color: t.dividerColor,
                                borderRadius: BorderRadius.circular(
                                  context.getRSize(2),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: context.getRSize(16)),
                          Row(
                            children: [
                              Icon(
                                FontAwesomeIcons.handHoldingDollar.data,
                                size: context.getRSize(18),
                                color: semantic.warning,
                              ),
                              SizedBox(width: context.getRSize(12)),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _title,
                                      style: t.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    Text(
                                      widget.driverName,
                                      style: t.textTheme.bodySmall?.copyWith(
                                        color: subtext,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: context.getRSize(10)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(20),
                          vertical: context.getRSize(10),
                        ),
                        children: [
                          Container(
                            padding: EdgeInsets.all(context.getRSize(14)),
                            decoration: BoxDecoration(
                              color: semantic.warning.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(
                                context.getRSize(12),
                              ),
                              border: Border.all(color: t.dividerColor),
                            ),
                            child: Text(
                              _isShortage
                                  ? 'The driver is liable for '
                                        '${formatCurrency(widget.owedKobo / 100)} '
                                        'of goods that left and cannot be '
                                        'accounted for. Writing it off forgives '
                                        'that debt and books the goods as a loss '
                                        'to the business.'
                                  : 'The driver is liable for '
                                        '${formatCurrency(widget.owedKobo / 100)} '
                                        'of damaged goods. Writing it off '
                                        'forgives that debt; the goods were '
                                        'already booked as a loss when the '
                                        'damage was recorded.',
                              style: t.textTheme.bodySmall?.copyWith(
                                color: t.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Amount to forgive',
                            controller: _amountCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [CurrencyInputFormatter()],
                            hintText: '0.00',
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Amount is required'
                                : null,
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Why (recorded on the driver\'s history)',
                            controller: _reasonCtrl,
                            hintText: 'e.g. Fell off on the Aba road',
                          ),
                          SizedBox(height: context.getRSize(20)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.getRSize(20),
                        context.getRSize(16),
                        context.getRSize(20),
                        context.deviceBottomPadding + context.getRSize(16),
                      ),
                      child: AppButton(
                        text: _saving ? 'Recording…' : 'Write it off',
                        onPressed: _saving ? null : _submit,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
