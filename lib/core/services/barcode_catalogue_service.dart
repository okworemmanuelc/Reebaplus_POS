import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/services/barcode_suggestion.dart';
import 'package:reebaplus_pos/core/utils/factory_barcode.dart';

/// The raw row of `public.barcode_suggestion` (ADR 0029 §4).
typedef BarcodeSuggestionRow = ({String? name, String? unit, String? photoUrl});

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
class BarcodeCatalogueService {
  BarcodeCatalogueService(SupabaseClient client)
    : this.withFetchers(
        fetchRow: (code) => _fetchRow(client, code),
        fetchPhoto: _fetchPublicObject,
      );

  /// For tests: swaps out the RPC call and the photo GET.
  @visibleForTesting
  BarcodeCatalogueService.withFetchers({
    required Future<BarcodeSuggestionRow?> Function(String code) fetchRow,
    required Future<Uint8List?> Function(Uri url) fetchPhoto,
    this.timeout = defaultTimeout,
  }) : _fetchRowFn = fetchRow,
       _fetchPhotoFn = fetchPhoto;

  static const defaultTimeout = Duration(seconds: 2);

  final Future<BarcodeSuggestionRow?> Function(String code) _fetchRowFn;
  final Future<Uint8List?> Function(Uri url) _fetchPhotoFn;

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
    if (FactoryBarcode.tryParse(code) == null) return null;

    final BarcodeSuggestionRow? row;
    try {
      row = await _fetchRowFn(code).timeout(timeout);
    } catch (e) {
      debugPrint('BarcodeCatalogueService: lookup skipped ($e)');
      return null;
    }
    if (row == null) return null;

    final photoBytes = includePhoto ? await _photo(row.photoUrl) : null;
    final suggestion = BarcodeSuggestion(
      name: _clean(row.name),
      unit: _clean(row.unit),
      photoBytes: photoBytes,
    );
    return suggestion.isEmpty ? null : suggestion;
  }

  Future<Uint8List?> _photo(String? photoUrl) async {
    final url = photoUrl == null ? null : Uri.tryParse(photoUrl);
    if (url == null || !url.hasScheme) return null;
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
