import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// One line the manager is counting, before it becomes a [VanReturnLine].
class _ReturnDraft {
  final String productId;
  final String productName;

  /// Starts at **0 and shows an empty field** — never a system-derived default.
  /// See the screen doc: that emptiness is the control, not an oversight.
  int quantity = 0;
  String condition = kVanReturnConditionGood;
  int shellsBack = 0;

  /// The idempotency key for this line, minted ONCE when the row is added and
  /// re-used across every retry, so a double-tap cannot credit twice.
  final String eventId = UuidV7.generate();

  _ReturnDraft({required this.productId, required this.productName});

  bool get isGood => condition == kVanReturnConditionGood;
}

/// Record a return (#143, PRD #139 / ADR 0019, van-sales spec §4.5, §5.2, §5.5,
/// §7.3, §9.3).
///
/// **The quantity field starts empty, deliberately, and there is no "return
/// everything left" button anywhere on this screen** (spec §7.3). Pre-filling
/// from system stock looks helpful and is the single most dangerous thing this
/// screen could do: if the driver's device still holds unsynced sales, the
/// system's idea of what is left is too high, so a manager who accepts the
/// default returns goods that were actually sold — turning real sales into
/// over-returns and hiding the shortage. The manager types what they can see
/// and count.
///
/// The two conditions do different things, and the screen says so out loud
/// before anything is written:
///
///  * **Good** — the driver is credited at the price those units were loaded at
///    (oldest load first), and the drinks go straight back into sellable stock
///    at the warehouse.
///  * **Damaged** — no credit at all. The driver still owes for them, and the
///    business books the loss at what the goods cost, not what they would have
///    sold for.
///
/// Gated `Gates.vanManage` at every layer: the hub hides the way in, the body
/// guard empties the screen on a live revocation, and [_submit] re-checks at the
/// write boundary. A Driver-role user holds `van.sell` and never this.
class VanReturnScreen extends ConsumerStatefulWidget {
  final VanTripData trip;
  final String driverName;
  final String vanName;

  const VanReturnScreen({
    super.key,
    required this.trip,
    required this.driverName,
    required this.vanName,
  });

  @override
  ConsumerState<VanReturnScreen> createState() => _VanReturnScreenState();
}

class _VanReturnScreenState extends ConsumerState<VanReturnScreen> {
  final List<_ReturnDraft> _lines = [];
  bool _submitting = false;

  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;

  void _addProduct(String productId, String productName) {
    if (_lines.any((l) => l.productId == productId)) {
      AppNotification.showError(
        context,
        '$productName is already on this return — edit its count.',
      );
      return;
    }
    setState(() {
      _lines.add(_ReturnDraft(productId: productId, productName: productName));
    });
  }

  Future<void> _submit() async {
    // Write-boundary re-check (layer 3, hard rule #6).
    if (!Gates.vanManage.allowsNow(ref)) {
      showGateDenied(context, Gates.vanManage);
      return;
    }
    if (_lines.isEmpty) {
      AppNotification.showError(context, 'Add at least one drink coming back.');
      return;
    }
    for (final line in _lines) {
      if (line.quantity <= 0) {
        AppNotification.showError(
          context,
          'Type how many came back — check ${line.productName}.',
        );
        return;
      }
    }

    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;

    setState(() => _submitting = true);
    try {
      final result = await ref.read(databaseProvider).vanTripsDao.recordReturn(
        tripId: widget.trip.id,
        performedBy: currentUser.id,
        lines: _lines
            .map(
              (l) => VanReturnLine(
                productId: l.productId,
                quantity: l.quantity,
                condition: l.condition,
                shellsBack: l.shellsBack,
                eventId: l.eventId,
              ),
            )
            .toList(growable: false),
      );
      if (!mounted) return;

      AppNotification.showSuccess(
        context,
        result.alreadyApplied
            ? 'This return was already recorded.'
            : result.totalCreditKobo > 0
            ? 'Return recorded — '
                  '${formatCurrency(result.totalCreditKobo / 100)} came off '
                  'what ${widget.driverName} owes.'
            : 'Damaged return recorded. ${widget.driverName} still owes for '
                  'these goods.',
      );
      Navigator.pop(context);
    } on VanOverReturnException catch (e) {
      if (!mounted) return;
      AppNotification.showError(context, e.message);
    } on VanTripNotOpenException catch (e) {
      if (!mounted) return;
      AppNotification.showError(context, e.message);
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not record the return. Nothing was changed — try again.',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    // Body guard (layer 2, hard rule #6).
    if (!Gates.vanManage.allows(ref)) {
      return GlassyScaffold(
        title: 'Record Return',
        body: _Empty(
          icon: FontAwesomeIcons.lock.data,
          title: 'No access',
          message: 'You no longer have access to Van Sales.',
        ),
      );
    }

    // The pickable set is "what went out on this trip" — you cannot return what
    // never left. Note what this is NOT: a quantity. The lots supply names only,
    // so no figure on this screen suggests how many should come back.
    final lots =
        ref.watch(vanTripLotsProvider(widget.trip.id)).valueOrNull ??
        const <VanTripLotData>[];
    final names = {
      for (final p
          in ref.watch(productsWithStockProvider(null)).valueOrNull ??
              const <ProductDataWithStock>[])
        p.product.id: p.product.name,
    };
    final loadedProducts = <String, String>{};
    for (final lot in lots) {
      loadedProducts.putIfAbsent(
        lot.productId,
        () => names[lot.productId] ?? 'Drink',
      );
    }
    final options = loadedProducts.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));

    final recorded =
        ref.watch(vanTripReturnsProvider(widget.trip.id)).valueOrNull ??
        const <VanReturnEventData>[];

    return GlassyScaffold(
      title: 'Record Return',
      subtitle: '${widget.driverName} • ${widget.vanName}',
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20),
          context.getRSize(20) + context.deviceBottomPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _CountItYourselfNote(),
            SizedBox(height: context.getRSize(16)),

            Autocomplete<MapEntry<String, String>>(
              displayStringForOption: (e) => e.value,
              optionsBuilder: (TextEditingValue v) {
                if (v.text.isEmpty) return const Iterable.empty();
                final q = v.text.toLowerCase();
                return options.where((e) => e.value.toLowerCase().contains(q));
              },
              onSelected: (e) => _addProduct(e.key, e.value),
              fieldViewBuilder: (ctx, controller, focusNode, onEditingComplete) {
                return AppInput(
                  controller: controller,
                  focusNode: focusNode,
                  labelText: 'Add a drink coming back',
                  onFieldSubmitted: (_) => onEditingComplete(),
                  prefixIcon: Icon(
                    FontAwesomeIcons.boxesStacked.data,
                    size: 14,
                    color: _subtext,
                  ),
                  hintText: options.isEmpty
                      ? 'Nothing was loaded on this trip'
                      : 'Start typing a drink name…',
                  enabled: options.isNotEmpty,
                );
              },
            ),
            SizedBox(height: context.getRSize(12)),

            if (_lines.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(16)),
                child: Text(
                  'Nothing on this return yet.',
                  style: t.textTheme.bodySmall?.copyWith(color: _subtext),
                ),
              )
            else
              ..._lines.map(
                (line) => _ReturnLineCard(
                  line: line,
                  onChanged: () => setState(() {}),
                  onRemove: () => setState(() => _lines.remove(line)),
                ),
              ),

            SizedBox(height: context.getRSize(20)),
            Guarded(
              gate: Gates.vanManage,
              builder: (context, allow) => AppButton(
                text: _submitting ? 'Recording…' : 'Record Return',
                icon: FontAwesomeIcons.arrowRotateLeft.data,
                onPressed: _submitting ? null : allow(_submit),
                isFullWidth: true,
              ),
            ),

            SizedBox(height: context.getRSize(28)),
            Text(
              'Already returned on this trip',
              style: t.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: context.getRSize(12)),
            if (recorded.isEmpty)
              Text(
                'Nothing has come back yet.',
                style: t.textTheme.bodySmall?.copyWith(color: _subtext),
              )
            else
              for (final e in recorded) ...[
                _RecordedReturnRow(
                  event: e,
                  productName: names[e.productId] ?? 'Drink',
                ),
                SizedBox(height: context.getRSize(10)),
              ],
          ],
        ),
      ),
    );
  }
}

/// Says the quiet part out loud, at the top of the screen: this is a physical
/// count. Without it a manager reasonably assumes the blank field is a bug.
class _CountItYourselfNote extends StatelessWidget {
  const _CountItYourselfNote();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: semantic.info.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(color: t.dividerColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            FontAwesomeIcons.clipboardCheck.data,
            size: context.getRSize(14),
            color: semantic.info,
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Text(
              'Count what actually came off the van and type it in. The app '
              'will not guess for you — sales the driver rang may not have '
              'reached this device yet.',
              style: t.textTheme.bodySmall?.copyWith(
                color: t.textTheme.bodySmall?.color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One drink coming back: the typed count, the condition, and the shell memo.
class _ReturnLineCard extends StatelessWidget {
  final _ReturnDraft line;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _ReturnLineCard({
    required this.line,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(10)),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(
          color: line.isGood ? t.dividerColor : semantic.warning,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  line.productName,
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                onPressed: onRemove,
                icon: Icon(
                  FontAwesomeIcons.xmark.data,
                  size: context.getRSize(14),
                ),
                tooltip: 'Remove',
              ),
            ],
          ),
          SizedBox(height: context.getRSize(4)),
          AppInput(
            labelText: 'How many came back',
            // NO initialValue and NO hint number: the emptiness is the control
            // (spec §7.3). A "0" hint would still anchor the manager.
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            hintText: 'Count them',
            onChanged: (v) {
              line.quantity = int.tryParse(v.trim()) ?? 0;
              onChanged();
            },
          ),
          SizedBox(height: context.getRSize(12)),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: kVanReturnConditionGood,
                label: Text('Good'),
              ),
              ButtonSegment(
                value: kVanReturnConditionDamaged,
                label: Text('Damaged'),
              ),
            ],
            selected: {line.condition},
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              line.condition = s.first;
              onChanged();
            },
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            line.isGood
                // The credit is FIFO over the lots (spec §9.3 #10), so the exact
                // figure is not knowable on this screen without re-implementing
                // the draw-down. Saying which price it uses is honest; printing
                // a number this screen would have to guess is not.
                ? 'Goes back into stock, and comes off what the driver owes at '
                      'the price it was loaded at.'
                : 'No credit — the driver still owes for these. The business '
                      'books the loss at what the goods cost.',
            style: t.textTheme.bodySmall?.copyWith(
              color: line.isGood ? subtext : semantic.warning,
            ),
          ),
          SizedBox(height: context.getRSize(10)),
          AppInput(
            // §11 — counting only. No deposit money moves in v1.
            labelText: 'Empty crates coming back (optional)',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            hintText: '0',
            onChanged: (v) {
              line.shellsBack = int.tryParse(v.trim()) ?? 0;
              onChanged();
            },
          ),
        ],
      ),
    );
  }
}

/// One already-recorded return — the duplicate-entry check.
class _RecordedReturnRow extends StatelessWidget {
  final VanReturnEventData event;
  final String productName;

  const _RecordedReturnRow({required this.event, required this.productName});

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final good = event.condition == kVanReturnConditionGood;

    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(color: t.dividerColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${event.quantity} × $productName',
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  [
                    good ? 'Good' : 'Damaged',
                    _date(event.recordedAt),
                    if (event.shellsBack > 0)
                      '${event.shellsBack} empty crates',
                  ].join(' • '),
                  style: t.textTheme.bodySmall?.copyWith(color: subtext),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(10)),
          Text(
            good ? '+${formatCurrency(event.creditKobo / 100)}' : 'No credit',
            style: t.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: good ? semantic.success : semantic.warning,
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String message;

  const _Empty({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Padding(
      padding: EdgeInsets.all(context.getRSize(28)),
      child: Column(
        children: [
          Icon(icon, size: context.getRSize(36), color: subtext),
          SizedBox(height: context.getRSize(12)),
          Text(
            title,
            style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            message,
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: subtext),
          ),
        ],
      ),
    );
  }
}
