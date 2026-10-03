import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/services/barcode_suggestion.dart';
import 'package:reebaplus_pos/core/services/catalogue_lookup.dart';
import 'package:reebaplus_pos/core/services/catalogue_report.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

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
  static const loadFailed = "Couldn't load the shared details. Try again later.";
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
    final theme = Theme.of(context);
    final lookup = _lookup;
    // A Material (not a decorated Container) so the checkbox tiles' ink shows.
    return Material(
      color: theme.scaffoldBackgroundColor,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(16),
          context.getRSize(20),
          context.getRSize(20) + context.deviceBottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              CatalogueReportSheet.title,
              style: TextStyle(
                fontSize: context.getRFontSize(18),
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.onSurface,
              ),
            ),
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
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: context.getRFontSize(13),
          ),
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
            dense: true,
          ),
        SizedBox(height: context.getRSize(8)),
        AppInput(
          controller: _noteController,
          labelText: CatalogueReportSheet.noteLabel,
          enabled: !_sending,
          maxLines: 3,
          minLines: 2,
          inputFormatters: [
            LengthLimitingTextInputFormatter(CatalogueReportSheet.noteMaxLength),
          ],
        ),
        if (error != null) ...[
          SizedBox(height: context.getRSize(12)),
          Text(
            error,
            style: TextStyle(
              color: theme.colorScheme.error,
              fontSize: context.getRFontSize(13),
            ),
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
class _SharedValues extends StatelessWidget {
  const _SharedValues({required this.shown});

  final BarcodeSuggestion shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = context.getRSize(64);
    final photoUrl = shown.photoUrl;
    final placeholder = Container(
      width: size,
      height: size,
      color: theme.dividerColor.withValues(alpha: 0.3),
      child: Icon(
        FontAwesomeIcons.image.data,
        size: context.getRSize(20),
        color: theme.textTheme.bodySmall?.color,
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
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
              _ValueRow(label: 'Unit', value: shown.unit),
              if (photoUrl == null) ...[
                SizedBox(height: context.getRSize(6)),
                const _ValueRow(label: 'Photo', value: null),
              ],
            ],
          ),
        ),
      ],
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
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: context.getRFontSize(13),
            ),
          ),
          TextSpan(
            text: shownValue ?? CatalogueReportSheet.notShared,
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              fontWeight: shownValue == null ? FontWeight.w400 : FontWeight.w700,
              fontStyle: shownValue == null ? FontStyle.italic : FontStyle.normal,
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
        style: TextStyle(
          fontSize: context.getRFontSize(14),
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
