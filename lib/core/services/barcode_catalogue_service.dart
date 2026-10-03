import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/services/barcode_suggestion.dart';
import 'package:reebaplus_pos/core/services/catalogue_lookup.dart';
import 'package:reebaplus_pos/core/services/catalogue_report.dart';
import 'package:reebaplus_pos/core/utils/factory_barcode.dart';
import 'package:reebaplus_pos/core/utils/network_failure.dart';

/// The raw row of `public.barcode_suggestion` (ADR 0029 §4).
typedef BarcodeSuggestionRow = ({String? name, String? unit, String? photoUrl});

/// One report as `report_barcode_catalogue_entry` takes it (ADR 0029 §6).
/// The reporter is never sent: the server takes it from the caller.
typedef CatalogueReportRequest = ({
  String businessId,
  String barcode,
  List<String> reasons,
  String? note,
  String? shownName,
  String? shownUnit,
  String? shownPhotoUrl,
});

/// Looks a factory barcode up in the shared barcode catalogue (ADR 0029 §8,
/// #332), for Add Product to fill in its empty boxes.
///
/// Sanctioned direct-Supabase exception (architecture.md): one read-only
/// definer RPC, `barcode_suggestion(p_barcode)`, plus a plain GET of the
/// public Storage object it names in `photo_url` (the shared bucket has no
/// `storage.objects` policies, so the authenticated download path can't read
/// it). Nothing is written, and no lookup result is kept on the phone.
///
/// Online only and quiet: each network step gives up after [timeout], and any
/// failure (offline, timeout, an error, zero rows) gives null, never an error.
/// A failed photo download keeps the name and unit.
///
/// Reports (#335, ADR 0029 §6): [lookupOutcome] is the same lookup but says
/// why nothing came back, for the report sheet; [report] calls the definer
/// RPC `report_barcode_catalogue_entry`, the one write this exception allows.
/// Online only, never queued.
class BarcodeCatalogueService {
  BarcodeCatalogueService(SupabaseClient client)
    : this.withFetchers(
        fetchRow: (code) => _fetchRow(client, code),
        fetchPhoto: _fetchPublicObject,
        sendReport: (request) => _sendReport(client, request),
      );

  /// For tests: swaps out the RPC calls and the photo GET.
  @visibleForTesting
  BarcodeCatalogueService.withFetchers({
    required Future<BarcodeSuggestionRow?> Function(String code) fetchRow,
    required Future<Uint8List?> Function(Uri url) fetchPhoto,
    Future<void> Function(CatalogueReportRequest request)? sendReport,
    this.timeout = defaultTimeout,
  }) : _fetchRowFn = fetchRow,
       _fetchPhotoFn = fetchPhoto,
       _sendReportFn = sendReport ?? _noSendReport;

  static const defaultTimeout = Duration(seconds: 2);

  final Future<BarcodeSuggestionRow?> Function(String code) _fetchRowFn;
  final Future<Uint8List?> Function(Uri url) _fetchPhotoFn;
  final Future<void> Function(CatalogueReportRequest request) _sendReportFn;

  /// How long each network step (the RPC, then the photo) may take.
  final Duration timeout;

  /// The suggestion for [code], or null when there is none or anything fails.
  /// A code that is not a factory GTIN returns null without a network call.
  /// [includePhoto] false skips the photo download (saves phone data when the
  /// caller can't use it).
  Future<BarcodeSuggestion?> lookup(
    String code, {
    bool includePhoto = true,
  }) async {
    final outcome = await lookupOutcome(code, includePhoto: includePhoto);
    return switch (outcome) {
      CatalogueFound(:final suggestion) when !suggestion.isEmpty => suggestion,
      CatalogueFound() ||
      CatalogueNothingShared() ||
      CatalogueUnreachable() ||
      CatalogueLookupFailed() => null,
    };
  }

  /// [lookup], saying how it ended. [CatalogueFound] carries the photo URL
  /// even when [includePhoto] is false or the download failed. A code that is
  /// not a factory GTIN is [CatalogueNothingShared] without a network call.
  Future<CatalogueLookup> lookupOutcome(
    String code, {
    bool includePhoto = true,
  }) async {
    if (FactoryBarcode.tryParse(code) == null) {
      return const CatalogueNothingShared();
    }

    final BarcodeSuggestionRow? row;
    try {
      row = await _fetchRowFn(code).timeout(timeout);
    } catch (e) {
      debugPrint('BarcodeCatalogueService: lookup skipped ($e)');
      return isNetworkFailure(e)
          ? const CatalogueUnreachable()
          : const CatalogueLookupFailed();
    }
    if (row == null) return const CatalogueNothingShared();

    final photoUrl = _photoUri(row.photoUrl);
    final photoBytes = includePhoto ? await _photo(photoUrl) : null;
    final suggestion = BarcodeSuggestion(
      name: _clean(row.name),
      unit: _clean(row.unit),
      photoBytes: photoBytes,
      photoUrl: photoUrl?.toString(),
    );
    if (suggestion.isEmpty && suggestion.photoUrl == null) {
      return const CatalogueNothingShared();
    }
    return CatalogueFound(suggestion);
  }

  /// Sends a report about what the catalogue showed for [barcode]. Gives up
  /// after [timeout]; nothing is queued. [reasons] must not be empty.
  /// A repeat from the same business for the same code updates its open
  /// report on the server, so sending again after a timeout is safe.
  Future<CatalogueReportResult> report({
    required String businessId,
    required String barcode,
    required Set<CatalogueReportReason> reasons,
    String? note,
    String? shownName,
    String? shownUnit,
    String? shownPhotoUrl,
  }) async {
    assert(reasons.isNotEmpty, 'a report needs at least one reason');
    final request = (
      businessId: businessId,
      barcode: barcode,
      reasons: [
        for (final r in CatalogueReportReason.values)
          if (reasons.contains(r)) r.wire,
      ],
      note: _clean(note),
      shownName: shownName,
      shownUnit: shownUnit,
      shownPhotoUrl: shownPhotoUrl,
    );
    try {
      await _sendReportFn(request).timeout(timeout);
      return const CatalogueReportSent();
    } catch (e) {
      debugPrint('BarcodeCatalogueService: report not sent ($e)');
      return isNetworkFailure(e)
          ? const CatalogueReportOffline()
          : const CatalogueReportFailed();
    }
  }

  static Uri? _photoUri(String? photoUrl) {
    final url = photoUrl == null ? null : Uri.tryParse(photoUrl);
    return (url == null || !url.hasScheme) ? null : url;
  }

  Future<Uint8List?> _photo(Uri? url) async {
    if (url == null) return null;
    try {
      final bytes = await _fetchPhotoFn(url).timeout(timeout);
      return (bytes == null || bytes.isEmpty) ? null : bytes;
    } catch (e) {
      debugPrint('BarcodeCatalogueService: photo skipped ($e)');
      return null;
    }
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  static Future<BarcodeSuggestionRow?> _fetchRow(
    SupabaseClient client,
    String code,
  ) async {
    final Object? rows = await client.rpc(
      'barcode_suggestion',
      params: {'p_barcode': code},
    );
    if (rows is! List || rows.isEmpty) return null;
    final row = rows.first;
    if (row is! Map) return null;
    String? text(String key) => switch (row[key]) {
      final String value => value,
      _ => null,
    };
    return (name: text('name'), unit: text('unit'), photoUrl: text('photo_url'));
  }

  static Future<void> _sendReport(
    SupabaseClient client,
    CatalogueReportRequest request,
  ) async {
    await client.rpc(
      'report_barcode_catalogue_entry',
      params: {
        'p_business_id': request.businessId,
        'p_barcode': request.barcode,
        'p_reasons': request.reasons,
        'p_note': request.note,
        'p_shown_name': request.shownName,
        'p_shown_unit': request.shownUnit,
        'p_shown_photo_url': request.shownPhotoUrl,
      },
    );
  }

  static Future<void> _noSendReport(CatalogueReportRequest request) =>
      Future.error(StateError('no sendReport fetcher given'));

  static Future<Uint8List?> _fetchPublicObject(Uri url) async {
    final http = HttpClient()..connectionTimeout = defaultTimeout;
    try {
      final request = await http.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      http.close(force: true);
    }
  }
}
