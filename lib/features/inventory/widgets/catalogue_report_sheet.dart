import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/services/barcode_suggestion.dart';
import 'package:reebaplus_pos/core/services/catalogue_lookup.dart';
import 'package:reebaplus_pos/core/services/catalogue_report.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/supplier_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// The sheet behind "Report a problem with the shared details" (ADR 0029 §6,
/// #335). It loads what the shared list shows for [barcode] right now (not
/// the shop's own copy), lets the person tick what's wrong, and sends one
/// report online. Nothing is queued. Pops `true` once the report is sent; the
/// caller shows the thank-you toast.
class CatalogueReportSheet extends ConsumerStatefulWidget {
  const CatalogueReportSheet({super.key, required this.barcode});

  /// A factory GTIN (the link only shows for one).
  final String barcode;

  static const title = 'Report a problem';
  static const intro =
      'This is what Reebaplus shares for this barcode with other shops. '
      'Tick what is wrong.';
  static const nothingShared = 'Nothing from this barcode is shared right now.';
  static const offline = 'Connect to the internet to send this report.';
  static const loadFailed =
      "Couldn't load the shared details. Try again later.";
  static const sendFailed = "Couldn't send the report. Try again.";
  static const notShared = 'Not shared';
  static const noteLabel = 'Note (optional)';
  static const sendLabel = 'Send';
  static const noteMaxLength = 500;

  static String reasonLabel(CatalogueReportReason reason) => switch (reason) {
    CatalogueReportReason.wrongName => 'Wrong name',
    CatalogueReportReason.wrongUnit => 'Wrong unit',
    CatalogueReportReason.badPhoto => 'Bad or private photo',
  };

  @override
  ConsumerState<CatalogueReportSheet> createState() =>
      _CatalogueReportSheetState();
}

class _CatalogueReportSheetState extends ConsumerState<CatalogueReportSheet> {
  final _noteController = TextEditingController();
  final _reasons = <CatalogueReportReason>{};

  /// Null while the lookup runs.
  CatalogueLookup? _lookup;
  bool _sending = false;

  /// The inline message after a failed send. Null when there is none.
  String? _sendError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // No photo bytes: the sheet shows the photo from its URL.
    final outcome = await ref
        .read(barcodeCatalogueServiceProvider)
        .lookupOutcome(widget.barcode, includePhoto: false);
    if (mounted) setState(() => _lookup = outcome);
  }

  Future<void> _send(BarcodeSuggestion shown) async {
    final businessId = ref.read(currentBusinessIdProvider);
    if (businessId == null) {
      setState(() => _sendError = CatalogueReportSheet.sendFailed);
      return;
    }
    setState(() {
      _sending = true;
      _sendError = null;
    });
    final result = await ref
        .read(barcodeCatalogueServiceProvider)
        .report(
          businessId: businessId,
          barcode: widget.barcode,
          reasons: Set.of(_reasons),
          note: _noteController.text,
          shownName: shown.name,
          shownUnit: shown.unit,
          shownPhotoUrl: shown.photoUrl,
        );
    if (!mounted) return;
    switch (result) {
      case CatalogueReportSent():
        Navigator.of(context).pop(true);
      case CatalogueReportOffline():
        setState(() {
          _sending = false;
          _sendError = CatalogueReportSheet.offline;
        });
      case CatalogueReportFailed():
        setState(() {
          _sending = false;
          _sendError = CatalogueReportSheet.sendFailed;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final lookup = _lookup;
    // The theme supplies the sheet's Surface and shape; this is a scrolling
    // column with the handle + title header (#392 PR 4).
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        context.getRSize(20) +
            context.deviceBottomPadding +
            inventorySheetKeyboardLift(context),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const InventorySheetHeader(title: CatalogueReportSheet.title),
          SizedBox(height: context.getRSize(12)),
          switch (lookup) {
            null => const _Loading(),
            CatalogueFound(:final suggestion) => _form(context, suggestion),
            CatalogueNothingShared() => const _Message(
              CatalogueReportSheet.nothingShared,
            ),
            CatalogueUnreachable() => const _Message(
              CatalogueReportSheet.offline,
            ),
            CatalogueLookupFailed() => const _Message(
              CatalogueReportSheet.loadFailed,
            ),
          },
        ],
      ),
    );
  }

  Widget _form(BuildContext context, BarcodeSuggestion shown) {
    final theme = Theme.of(context);
    final error = _sendError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          CatalogueReportSheet.intro,
          style: context
              .regularStyle(13)
              .copyWith(color: theme.textTheme.bodySmall?.color),
        ),
        SizedBox(height: context.getRSize(12)),
        _SharedValues(shown: shown),
        SizedBox(height: context.getRSize(8)),
        for (final reason in CatalogueReportReason.values)
          CheckboxListTile(
            value: _reasons.contains(reason),
            onChanged: _sending
                ? null
                : (ticked) => setState(() {
                    if (ticked ?? false) {
                      _reasons.add(reason);
                    } else {
                      _reasons.remove(reason);
                    }
                  }),
            title: Text(CatalogueReportSheet.reasonLabel(reason)),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        SizedBox(height: context.getRSize(8)),
        AppInput(
          controller: _noteController,
          labelText: CatalogueReportSheet.noteLabel,
          enabled: !_sending,
          maxLines: 3,
          minLines: 2,
          inputFormatters: [
            LengthLimitingTextInputFormatter(
              CatalogueReportSheet.noteMaxLength,
            ),
          ],
        ),
        if (error != null) ...[
          SizedBox(height: context.getRSize(12)),
          Text(
            error,
            style: context
                .semiBoldStyle(13)
                .copyWith(color: theme.colorScheme.error),
          ),
        ],
        SizedBox(height: context.getRSize(16)),
        AppButton(
          text: CatalogueReportSheet.sendLabel,
          isLoading: _sending,
          onPressed: _reasons.isEmpty || _sending ? null : () => _send(shown),
        ),
      ],
    );
  }
}

/// The shared name, unit and photo, as the catalogue returned them.
class _SharedValues extends ConsumerWidget {
  const _SharedValues({required this.shown});

  final BarcodeSuggestion shown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crates = businessTracksCrates(ref.watch(currentBusinessProvider));
    final theme = Theme.of(context);
    final size = context.getRSize(64);
    final photoUrl = shown.photoUrl;
    final placeholder = Container(
      width: size,
      height: size,
      color: theme.dividerColor.withValues(alpha: 0.3),
      child: Icon(
        AppIcons.image,
        size: context.getRSize(20),
        color: theme.textTheme.bodySmall?.color,
      ),
    );
    return Container(
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: AppDecorations.card(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
            child: photoUrl == null
                ? placeholder
                : Image.network(
                    photoUrl,
                    key: const ValueKey('catalogue-report-photo'),
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => placeholder,
                  ),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ValueRow(label: 'Name', value: shown.name),
                SizedBox(height: context.getRSize(6)),
                _ValueRow(
                  label: 'Unit',
                  value: unitLabel(shown.unit, crates: crates),
                ),
                if (photoUrl == null) ...[
                  SizedBox(height: context.getRSize(6)),
                  const _ValueRow(label: 'Photo', value: null),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shownValue = value;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: context
                .regularStyle(13)
                .copyWith(color: theme.textTheme.bodySmall?.color),
          ),
          TextSpan(
            text: shownValue ?? CatalogueReportSheet.notShared,
            style:
                (shownValue == null
                        ? context.regularStyle(14)
                        : context.boldStyle(14))
                    .copyWith(
                      fontStyle: shownValue == null
                          ? FontStyle.italic
                          : FontStyle.normal,
                      color: theme.colorScheme.onSurface,
                    ),
          ),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(24)),
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(16)),
      child: Text(
        text,
        style: context
            .regularStyle(14)
            .copyWith(color: Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}
