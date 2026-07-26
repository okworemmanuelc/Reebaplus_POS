import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';

/// Record Payment — the manager logs cash a driver handed in (#144, PRD #139 /
/// ADR 0019 decision 2, van-sales spec §5.3).
///
/// Modelled on the supplier Record Payment sheet, with one deliberate
/// difference: proof is **optional** here. A supplier payment is money leaving
/// the business to an outside party; a driver remittance is money *arriving*,
/// counted in front of the person who handed it over, and demanding a receipt
/// before the balance can be corrected would push managers to not record it.
///
/// **A driver can never reach this sheet.** It is opened only from the Van
/// Sales hub, which is behind `Gates.vanManage` (CEO + Manager); a driver holds
/// `van.sell` and never `van.manage`. The submit path re-checks the live gate
/// at fire time, so a revocation mid-form blocks the write too (spec §9.5 #21 —
/// impossible by construction, not merely unreachable).
class RecordDriverPaymentSheet extends ConsumerStatefulWidget {
  final VanTripData trip;
  final String driverName;

  const RecordDriverPaymentSheet({
    super.key,
    required this.trip,
    required this.driverName,
  });

  static Future<void> show(
    BuildContext context, {
    required VanTripData trip,
    required String driverName,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          RecordDriverPaymentSheet(trip: trip, driverName: driverName),
    );
  }

  @override
  ConsumerState<RecordDriverPaymentSheet> createState() =>
      _RecordDriverPaymentSheetState();
}

class _RecordDriverPaymentSheetState
    extends ConsumerState<RecordDriverPaymentSheet> {
  final _amountCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String _method = 'cash';
  PlatformFile? _receipt;
  bool _saving = false;

  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickReceipt() async {
    AutoLockWrapper.suppressNextResume = true;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'png', 'pdf'],
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() => _receipt = result.files.first);
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false) || _saving) return;

    // Write-boundary re-check (ADR 0002 layer 3): the sheet is only reachable
    // from a van.manage surface, but a revocation while the form is open must
    // block the write, not just hide the button.
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

    final note = _refCtrl.text.trim();
    setState(() => _saving = true);
    try {
      final result = await ref
          .read(databaseProvider)
          .vanTripsDao
          .recordDriverPayment(
            tripId: widget.trip.id,
            amountKobo: amountKobo,
            method: _method,
            performedBy: staffId,
            receiptPath: _receipt?.path,
            referenceNote: note.isEmpty ? null : note,
          );
      if (!mounted) return;
      Navigator.pop(context);
      final owed = result.driverBalanceKoboAfter;
      AppNotification.showSuccess(
        context,
        '${formatCurrency(amountKobo / 100)} from ${widget.driverName} '
        'recorded. '
        '${owed < 0 ? '${formatCurrency(-owed / 100)} still owed.' : owed == 0 ? 'Settled.' : 'In credit ${formatCurrency(owed / 100)}.'}',
      );
    } on VanTripNotOpenException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppNotification.showError(context, e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppNotification.showError(context, 'Could not record the payment.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final balanceKobo = ref
        .watch(driverBalanceProvider(widget.trip.driverUserId))
        .valueOrNull;
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final sourceName = stores
        .where((s) => s.id == widget.trip.sourceStoreId)
        .map((s) => s.name)
        .firstOrNull;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context),
      // Opens at full size (initial == max) so the keyboard has no room to grow
      // the sheet — the "form jumps up" fix used by every sheet in this app.
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.85,
        snap: true,
        snapSizes: const [0.5, 0.85],
        builder: (context, scrollController) {
          return GestureDetector(
            onTap: () {},
            child: Container(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
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
                                color: _border,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          SizedBox(height: context.getRSize(16)),
                          _header(semantic.success),
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
                          _banner(sourceName, balanceKobo),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Amount handed in',
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
                          AppDropdown<String>(
                            labelText: 'How it was paid',
                            value: _method,
                            items: const [
                              DropdownMenuItem(
                                value: 'cash',
                                child: Text('Cash'),
                              ),
                              DropdownMenuItem(
                                value: 'transfer',
                                child: Text('Bank Transfer'),
                              ),
                              DropdownMenuItem(
                                value: 'pos',
                                child: Text('POS Card'),
                              ),
                              DropdownMenuItem(
                                value: 'other',
                                child: Text('Other'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => _method = v);
                            },
                          ),
                          SizedBox(height: context.getRSize(16)),
                          _proofSection(),
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
                        text: _saving ? 'Recording…' : 'Record Payment',
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

  Widget _header(Color accent) {
    return Row(
      children: [
        Container(
          width: context.getRSize(44),
          height: context.getRSize(44),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            FontAwesomeIcons.moneyBillTransfer.data,
            color: accent,
            size: context.getRSize(20),
          ),
        ),
        SizedBox(width: context.getRSize(14)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Record Payment',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: _text,
                ),
              ),
              Text(
                widget.driverName,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: accent),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// States the two facts a manager needs before typing a figure: where the
  /// money is being booked (the SOURCE WAREHOUSE — cash comes back to the yard,
  /// never to the van) and what the driver currently owes.
  Widget _banner(String? sourceName, int? balanceKobo) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FontAwesomeIcons.store.data,
                size: context.getRSize(13),
                color: primary,
              ),
              SizedBox(width: context.getRSize(8)),
              Expanded(
                child: Text(
                  'Booked to ${sourceName ?? 'the loading store'}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: _subtext),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (balanceKobo != null) ...[
            SizedBox(height: context.getRSize(8)),
            Row(
              children: [
                Icon(
                  FontAwesomeIcons.scaleBalanced.data,
                  size: context.getRSize(13),
                  color: balanceKobo < 0
                      ? Theme.of(context).colorScheme.error
                      : _subtext,
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: Text(
                    balanceKobo < 0
                        ? 'Owes ${formatCurrency(-balanceKobo / 100)}'
                        : balanceKobo == 0
                        ? 'Settled'
                        : 'In credit ${formatCurrency(balanceKobo / 100)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: balanceKobo < 0
                          ? Theme.of(context).colorScheme.error
                          : _subtext,
                      fontWeight: FontWeight.w700,
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

  /// Optional proof — a receipt photo and/or a free-text reference. Unlike the
  /// supplier flow this is not required (see the class doc).
  Widget _proofSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Proof (optional)',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        SizedBox(height: context.getRSize(4)),
        Text(
          'Attach a photo of the hand-over slip, or note a transfer reference. '
          'The photo stays on this device.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: _subtext),
        ),
        SizedBox(height: context.getRSize(12)),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _pickReceipt,
          child: Container(
            padding: EdgeInsets.all(context.getRSize(14)),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: Row(
              children: [
                Icon(
                  _receipt == null
                      ? FontAwesomeIcons.paperclip.data
                      : FontAwesomeIcons.solidFileLines.data,
                  size: context.getRSize(16),
                  color: _receipt == null
                      ? _subtext
                      : Theme.of(context).colorScheme.primary,
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Text(
                    _receipt?.name ?? 'Attach a photo or file',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _receipt == null ? _subtext : _text,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_receipt != null)
                  GestureDetector(
                    onTap: () => setState(() => _receipt = null),
                    child: Icon(
                      Icons.close,
                      size: context.getRSize(18),
                      color: _subtext,
                    ),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(height: context.getRSize(16)),
        AppInput(
          labelText: 'Reference / Note',
          controller: _refCtrl,
          maxLines: 2,
          hintText: 'e.g. TRF-20938 / handed over at the yard',
        ),
      ],
    );
  }
}
