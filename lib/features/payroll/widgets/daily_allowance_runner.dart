import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

/// #669 — runs the automatic Daily Allowance ([PayrollAllowances.runDailyAllowances])
/// without any network: when the app opens, when it comes back to the
/// foreground, whenever the Payroll worker list changes (sign-in, a new
/// worker, a pulled change), and every [interval] while it stays open (a till
/// left on overnight still posts the new day). The pull path runs it too
/// (`SupabaseSyncService`). Idempotent and a no-op on a phone without Payroll,
/// so running it often is safe.
class DailyAllowanceRunner extends ConsumerStatefulWidget {
  const DailyAllowanceRunner({
    super.key,
    required this.child,
    this.interval = const Duration(minutes: 30),
  });

  final Widget child;
  final Duration interval;

  @override
  ConsumerState<DailyAllowanceRunner> createState() =>
      _DailyAllowanceRunnerState();
}

class _DailyAllowanceRunnerState extends ConsumerState<DailyAllowanceRunner>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(widget.interval, (_) => _run());
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _run();
  }

  Future<void> _run() async {
    if (_running || !mounted) return;
    _running = true;
    try {
      await ref.read(databaseProvider).payrollDao.runDailyAllowances();
    } catch (e) {
      debugPrint('[DailyAllowanceRunner] skipped: $e');
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<List<PayrollWorkerData>>>(payrollWorkersProvider, (
      _,
      next,
    ) {
      if (next.hasValue) _run();
    });
    return widget.child;
  }
}
