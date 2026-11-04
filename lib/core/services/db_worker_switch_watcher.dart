import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reebaplus_pos/core/database/local_database_connection.dart';
import 'package:reebaplus_pos/main.dart' show supabaseReady;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Minimum gap between two cloud reads (launch + resume are debounced).
const Duration kDbWorkerSwitchCheckGap = Duration(minutes: 1);

/// Reads the cloud off switch (`app_config` key `db_background_worker`,
/// migration 0252; anon-readable, so it works before sign-in and even when the
/// local database failed to open).
///
/// Returns true for "on", false for "off", and null on ANY failure (offline,
/// timeout, missing row, junk value): no answer changes nothing.
typedef DbWorkerSwitchFetcher = Future<bool?> Function();

Future<bool?> fetchDbWorkerSwitch() async {
  try {
    await supabaseReady.timeout(const Duration(seconds: 5));
    final row = await Supabase.instance.client
        .from('app_config')
        .select('value')
        .eq('key', kDbBackgroundWorkerConfigKey)
        .maybeSingle()
        .timeout(const Duration(seconds: 5));
    return switch ((row?['value'] as String?)?.trim()) {
      'on' => true,
      'off' => false,
      _ => null,
    };
  } catch (e) {
    debugPrint('[DbWorkerSwitch] fetch failed: $e');
    return null;
  }
}

/// Reads the off switch on launch and resume and remembers the answer for the
/// next app open. Runs after the database is open and is never awaited, so it
/// cannot delay anything. It never touches the open connection.
class DbWorkerSwitchWatcher with WidgetsBindingObserver {
  DbWorkerSwitchWatcher({
    DbWorkerSwitchFetcher? fetch,
    Future<Directory> Function()? directory,
  }) : _fetch = fetch ?? fetchDbWorkerSwitch,
       _directory = directory ?? getApplicationDocumentsDirectory;

  final DbWorkerSwitchFetcher _fetch;
  final Future<Directory> Function() _directory;
  bool _inFlight = false;
  DateTime? _lastCheck;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(check());
  }

  Future<void> check() async {
    if (_inFlight) return;
    final last = _lastCheck;
    if (last != null &&
        DateTime.now().difference(last) < kDbWorkerSwitchCheckGap) {
      return;
    }
    _inFlight = true;
    _lastCheck = DateTime.now();
    try {
      final answer = await _fetch();
      await DbWorkerSwitch(await _directory()).remember(answer);
    } catch (e) {
      debugPrint('[DbWorkerSwitch] remember failed: $e');
    } finally {
      _inFlight = false;
    }
  }
}
