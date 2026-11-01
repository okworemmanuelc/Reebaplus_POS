import 'package:flutter/foundation.dart';
import 'package:reebaplus_pos/main.dart' show supabaseReady;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads the server-held minimum Android build number (`app_config`
/// key `min_android_build`, migration 0240; anon-readable).
///
/// Returns null on ANY failure (offline, timeout, missing row, junk value):
/// the must-update switch only ever blocks on a positive answer from the
/// server, never on an error (offline-first entry gate).
typedef MinBuildFetcher = Future<int?> Function();

Future<int?> fetchMinAndroidBuild() async {
  try {
    await supabaseReady.timeout(const Duration(seconds: 5));
    final row = await Supabase.instance.client
        .from('app_config')
        .select('value')
        .eq('key', 'min_android_build')
        .maybeSingle()
        .timeout(const Duration(seconds: 5));
    return int.tryParse((row?['value'] as String?)?.trim() ?? '');
  } catch (e) {
    debugPrint('[MinBuild] fetch failed: $e');
    return null;
  }
}
