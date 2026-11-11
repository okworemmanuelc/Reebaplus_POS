import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/crates/crate_bearing_sale.dart';
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
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// One line the manager is counting, before it becomes a [VanReturnLine].
class _ReturnDraft {
  final String productId;
  final String productName;

  /// Starts at **0 and shows an empty field** — never a system-derived default.
  /// See the screen doc: that emptiness is the control, not an oversight.
  int quantity = 0;
  String condition = kVanReturnConditionGood;

  /// The EMPTY crates counted back (#726) — separate from [quantity], which is
  /// the unsold FULL crates. Null until the manager types it: for a
  /// crate-tracked product the line cannot be saved while it is null (0 is a
  /// valid answer). Stays 0 where [crateTracked] is false.
  int? shellsBack;

  /// Whether this product's empties are tracked (crate business, bottle,
  /// track-empties on, has a brand) — decided once when the row is added.
  final bool crateTracked;

  /// The idempotency key for this line, minted ONCE when the row is added and
  /// re-used across every retry, so a double-tap cannot credit twice.
  final String eventId = UuidV7.generate();

  _ReturnDraft({
    required this.productId,
    required this.productName,
    this.crateTracked = false,
  });

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
///    (oldest load first), and the goods go straight back into sellable stock
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

  /// Whether [productId] is a crate-tracked bottle with a brand in a business
  /// that tracks crates — the products whose empties must be counted.
  bool _isCrateTracked(String productId) {
    if (!businessTracksCrates(ref.read(currentBusinessProvider))) return false;
    for (final p
        in ref.read(productsWithStockProvider(null)).valueOrNull ??
            const <ProductDataWithStock>[]) {
      if (p.product.id != productId) continue;
      return p.product.manufacturerId != null &&
          isCrateTrackedBottle((
            unit: p.product.unit,
            trackEmpties: p.product.trackEmpties,
          ));
    }
    return false;
  }

  /// Every product that went out on this trip gets a row straight away
  /// (#790), so nobody types a name: staff only type a count beside what came
  /// back. What a row carries is the NAME; its count stays empty (the control
  /// in the class doc is untouched). Waits for the product list, because that
  /// is what says whether a row's empties must be counted.
  void _listLoaded(Map<String, String> loadedProducts) {
    if (!ref.read(productsWithStockProvider(null)).hasValue) return;
    final listed = {for (final l in _lines) l.productId};
    final missing = loadedProducts.entries
        .where((e) => !listed.contains(e.key))
        .toList();
    if (missing.isEmpty) return;
    for (final e in missing) {
      _lines.add(
        _ReturnDraft(
          productId: e.key,
          productName: e.value,
          crateTracked: _isCrateTracked(e.key),
        ),
      );
    }
    _lines.sort(
      (a, b) =>
          a.productName.toLowerCase().compareTo(b.productName.toLowerCase()),
    );
  }

  Future<void> _submit() async {
    // Write-boundary re-check (layer 3, hard rule #6).
    if (!Gates.vanManage.allowsNow(ref)) {
      showGateDenied(context, Gates.vanManage);
      return;
    }
    // Only the rows with something typed are part of this return; the rest
    // of the list is just what is on the van.
    final counted = [
      for (final l in _lines)
        if (l.quantity > 0 || (l.shellsBack ?? 0) > 0) l,
    ];
    if (counted.isEmpty) {
      AppNotification.showError(
        context,
        'Type how many came back beside at least one item.',
      );
      return;
    }
    for (final line in counted) {
      // Goods came back on a crate product: the empties must be counted too
      // (0 is a valid answer). Empties ALONE need no goods count (#790).
      if (line.quantity > 0 && line.crateTracked && line.shellsBack == null) {
        AppNotification.showError(
          context,
          'Count the empty crates for ${line.productName} — type 0 if none '
          'came back.',
        );
        return;
      }
    }

    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;

    setState(() => _submitting = true);
    try {
      final result = await ref
          .read(databaseProvider)
          .vanTripsDao
          .recordReturn(
            tripId: widget.trip.id,
            performedBy: currentUser.id,
            lines: counted
                .map(
                  (l) => VanReturnLine(
                    productId: l.productId,
                    quantity: l.quantity,
                    // Empties alone are not goods, so never 'damaged'.
                    condition: l.quantity > 0
                        ? l.condition
                        : kVanReturnConditionGood,
                    shellsBack: l.shellsBack ?? 0,
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
            : counted.every((l) => l.quantity == 0)
            ? 'Empty crates recorded.'
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
    // The trade's own word for a sellable item (ADR 0015) — a pharmacy counts
    // medicines off the van, not drinks.
    final lex = ref.watch(industryLexiconProvider);
    // Empties are a Bar/Beverage concept; no other trade is asked to count them.
    final tracksCrates = businessTracksCrates(
      ref.watch(currentBusinessProvider),
    );

    // Body guard (layer 2, hard rule #6).
    if (!Gates.vanManage.allows(ref)) {
      return const GlassyScaffold(
        title: 'Record Return',
        body: _Empty(
          icon: AppIcons.lock,
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
        () => names[lot.productId] ?? lex.item,
      );
    }
    _listLoaded(loadedProducts);

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

            if (_lines.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(16)),
                child: Text(
                  'Nothing was loaded on this trip.',
                  style: t.textTheme.bodySmall?.copyWith(color: _subtext),
                ),
              )
            else
              ..._lines.map(
                (line) => _ReturnLineCard(
                  key: ValueKey('return-line-${line.productId}'),
                  line: line,
                  onChanged: () => setState(() {}),
                ),
              ),

            SizedBox(height: context.getRSize(20)),
            Guarded(
              gate: Gates.vanManage,
              builder: (context, allow) => AppButton(
                key: const Key('return-submit'),
                text: _submitting ? 'Recording…' : 'Record Return',
                icon: AppIcons.undo,
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
                  showCrates: tracksCrates,
                  productName: names[e.productId] ?? lex.item,
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
            AppIcons.auditCheck,
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

/// One product that is on the van: its name and an empty count box. The
/// condition and, for a crate business, the empties box open only once a count
/// is typed, so a van with twenty products is a short list, not twenty forms.
class _ReturnLineCard extends StatelessWidget {
  final _ReturnDraft line;
  final VoidCallback onChanged;

  const _ReturnLineCard({
    super.key,
    required this.line,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final counted = line.quantity > 0;
    final emptiesOnly = !counted && (line.shellsBack ?? 0) > 0;

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(8)),
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(8),
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(
          color: emptiesOnly
              ? t.colorScheme.primary
              : !counted
              ? t.dividerColor
              : line.isGood
              ? t.colorScheme.primary
              : semantic.warning,
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
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(width: context.getRSize(8)),
              SizedBox(
                width: context.getRSize(96),
                child: TextField(
                  key: Key('return-qty-${line.productId}'),
                  // NO initial value and NO hint number: the emptiness is the
                  // control (spec §7.3). A "0" hint would still anchor the
                  // manager.
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: t.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Count',
                    contentPadding: EdgeInsets.symmetric(
                      vertical: context.getRSize(8),
                    ),
                  ),
                  onChanged: (v) {
                    line.quantity = int.tryParse(v.trim()) ?? 0;
                    onChanged();
                  },
                ),
              ),
            ],
          ),
          if (line.crateTracked) ...[
            SizedBox(height: context.getRSize(6)),
            Row(
              children: [
                Expanded(
                  child: Text(
                    // #726 / #790 — counted SEPARATELY from the full crates
                    // above, and may be recorded on their own.
                    counted
                        ? 'Empty crates back (0 if none)'
                        : 'Empty crates back',
                    style: t.textTheme.bodySmall?.copyWith(color: subtext),
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                SizedBox(
                  width: context.getRSize(96),
                  child: TextField(
                    key: Key('return-shells-${line.productId}'),
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Count',
                      contentPadding: EdgeInsets.symmetric(
                        vertical: context.getRSize(8),
                      ),
                    ),
                    onChanged: (v) {
                      line.shellsBack = int.tryParse(v.trim());
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
          ],
          if (counted) ...[
            SizedBox(height: context.getRSize(8)),
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
            SizedBox(height: context.getRSize(6)),
            Text(
              line.isGood
                  // The credit is FIFO over the lots (spec §9.3 #10), so the
                  // exact figure is not knowable here without re-implementing
                  // the draw-down. Saying which price it uses is honest;
                  // printing a number this screen would have to guess is not.
                  ? 'Goes back into stock, and comes off what the driver owes '
                        'at the price it was loaded at.'
                  : 'No credit — the driver still owes for these. The '
                        'business books the loss at what the goods cost.',
              style: t.textTheme.bodySmall?.copyWith(
                color: line.isGood ? subtext : semantic.warning,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One already-recorded return — the duplicate-entry check.
class _RecordedReturnRow extends StatelessWidget {
  final VanReturnEventData event;
  final String productName;

  /// Whether to print the shell count alongside the condition and date.
  final bool showCrates;

  const _RecordedReturnRow({
    required this.event,
    required this.productName,
    required this.showCrates,
  });

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
                  event.quantity == 0
                      ? 'Empty crates only — $productName'
                      : '${event.quantity} × $productName',
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  [
                    good ? 'Good' : 'Damaged',
                    _date(event.recordedAt),
                    if (showCrates && event.shellsBack > 0)
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
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
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
