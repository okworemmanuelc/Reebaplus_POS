import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/diagnostics/sync_diagnostic.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// Result of asking the cloud for the `profiles` row backing the current
/// session. This is what `get_user_business_id()` will resolve to and thus
/// what RLS will enforce for every tenant insert/select.
class _ProfileProbe {
  final bool fetched;
  final bool found;
  final String? businessId;
  final String? error;
  const _ProfileProbe.loading()
      : fetched = false,
        found = false,
        businessId = null,
        error = null;
  const _ProfileProbe.notFound()
      : fetched = true,
        found = false,
        businessId = null,
        error = null;
  const _ProfileProbe.ok(String? bid)
      : fetched = true,
        found = true,
        businessId = bid,
        error = null;
  const _ProfileProbe.failed(String e)
      : fetched = true,
        found = false,
        businessId = null,
        error = e;
}

enum _SyncErrorKind { rls, missingBusinessId, duplicateKey, fk, network, other }

_SyncErrorKind _classify(String? error) {
  if (error == null) return _SyncErrorKind.other;
  final e = error.toLowerCase();
  if (e == 'missing_business_id') return _SyncErrorKind.missingBusinessId;
  if (e.contains('row-level security')) return _SyncErrorKind.rls;
  if (e.contains('duplicate key')) return _SyncErrorKind.duplicateKey;
  if (e.contains('violates foreign key')) return _SyncErrorKind.fk;
  if (e.contains('socketexception') || e.contains('timeoutexception')) {
    return _SyncErrorKind.network;
  }
  return _SyncErrorKind.other;
}

String _labelFor(_SyncErrorKind kind) {
  switch (kind) {
    case _SyncErrorKind.rls:
      return 'RLS rejection';
    case _SyncErrorKind.missingBusinessId:
      return 'Missing business_id';
    case _SyncErrorKind.duplicateKey:
      return 'Duplicate key';
    case _SyncErrorKind.fk:
      return 'FK violation';
    case _SyncErrorKind.network:
      return 'Network';
    case _SyncErrorKind.other:
      return 'Other';
  }
}

class SyncIssuesScreen extends ConsumerStatefulWidget {
  const SyncIssuesScreen({super.key});

  @override
  ConsumerState<SyncIssuesScreen> createState() => _SyncIssuesScreenState();
}

class _SyncIssuesScreenState extends ConsumerState<SyncIssuesScreen> {
  bool _auditExpanded = false;
  bool _auditRunning = false;
  List<TableDiagnosticRow>? _auditResults;
  _ProfileProbe _profile = const _ProfileProbe.loading();
  List<String> _deferredTables = const [];
  bool _retryingDeferred = false;
  final _serviceKeyCtl = TextEditingController();
  final _projectUrlCtl = TextEditingController();

  // Captured at initState — the per-item retry callbacks await first then
  // schedule a `pushPending`; touching `ref` after the await would race the
  // riverpod element-unmount invalidation. See plan §"Bug fix" Pattern 1.
  late final SupabaseSyncService _sync;
  late final AppDatabase _db;

  @override
  void initState() {
    super.initState();
    _sync = ref.read(supabaseSyncServiceProvider);
    _db = ref.read(databaseProvider);
    unawaited(_probeProfile());
    unawaited(_loadDeferredTables());
  }

  Future<void> _loadDeferredTables() async {
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) {
      if (mounted) setState(() => _deferredTables = const []);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw =
        prefs.getString(SupabaseSyncService.pendingDeferredTablesKey(businessId));
    if (!mounted) return;
    setState(() {
      _deferredTables = (raw == null || raw.isEmpty)
          ? const []
          : raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    });
  }

  Future<void> _retryDeferredPull() async {
    if (_retryingDeferred) return;
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) return;
    setState(() => _retryingDeferred = true);
    final sync = ref.read(supabaseSyncServiceProvider);
    try {
      await sync.syncAll(businessId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Re-sync complete.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Re-sync failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _retryingDeferred = false);
      await _loadDeferredTables();
    }
  }

  @override
  void dispose() {
    _serviceKeyCtl.dispose();
    _projectUrlCtl.dispose();
    super.dispose();
  }

  Future<void> _probeProfile() async {
    final supa = Supabase.instance.client;
    final user = supa.auth.currentUser;
    if (user == null) {
      if (mounted) setState(() => _profile = const _ProfileProbe.failed('no session'));
      return;
    }
    try {
      final rows = await supa
          .from('profiles')
          .select('business_id')
          .eq('id', user.id);
      final list = rows as List;
      if (list.isEmpty) {
        if (mounted) setState(() => _profile = const _ProfileProbe.notFound());
        return;
      }
      final raw = (list.first as Map)['business_id'];
      final bid = raw?.toString();
      if (mounted) setState(() => _profile = _ProfileProbe.ok(bid));
    } catch (e) {
      if (mounted) setState(() => _profile = _ProfileProbe.failed(e.toString()));
    }
  }

  Future<void> _runAudit() async {
    final businessId = ref.read(authProvider).currentUser?.businessId;
    if (businessId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active business — sign in first.')),
      );
      return;
    }
    setState(() {
      _auditRunning = true;
      _auditResults = null;
    });
    final diag = ref.read(syncDiagnosticProvider);
    final results = await diag.run(
      businessId,
      serviceRoleKey: _serviceKeyCtl.text,
      projectUrl: _projectUrlCtl.text,
    );
    if (!mounted) return;
    setState(() {
      _auditRunning = false;
      _auditResults = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final failedAsync = ref.watch(failedQueueItemsProvider);
    final orphanAsync = ref.watch(orphanQueueItemsProvider);
    final pendingCount = ref.watch(pendingQueueCountProvider).valueOrNull ?? 0;
    final failedCount = ref.watch(failedQueueCountProvider).valueOrNull ?? 0;
    final orphanCount = ref.watch(orphanQueueCountProvider).valueOrNull ?? 0;
    final claims = SupabaseSyncService.inspectJwtClaims();
    final businessId = ref.read(authProvider).currentUser?.businessId;

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Sync Issues',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + context.bottomInset),
        children: [
          _sectionHeader(t, 'Health'),
          const SizedBox(height: 12),
          _healthCard(t,
              businessId: businessId,
              claims: claims,
              profile: _profile,
              pending: pendingCount,
              failed: failedCount,
              orphaned: orphanCount),
          const SizedBox(height: 28),
          if (_deferredTables.isNotEmpty) ...[
            _sectionHeader(t, 'Catching up'),
            const SizedBox(height: 12),
            _deferredCard(t, _deferredTables),
            const SizedBox(height: 28),
          ],
          _sectionHeader(t, 'Failed items'),
          const SizedBox(height: 12),
          failedAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => _emptyCard(t, 'Failed to load: $e'),
            data: (items) {
              if (items.isEmpty) {
                return _emptyCard(t, 'No failed items.');
              }
              return Column(
                children: [
                  for (final item in items) _failedItemTile(t, item),
                ],
              );
            },
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(child: _sectionHeader(t, 'Orphaned items')),
              if (orphanCount > 0)
                TextButton(
                  onPressed: () => _retryAllOrphans(),
                  child: const Text('Retry all'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Permanent failures auto-archived out of the queue. Surface here so '
            'a "Push/RLS gap" in the audit below has a visible cause.',
            style: TextStyle(
              fontSize: 12,
              color: t.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 12),
          orphanAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => _emptyCard(t, 'Failed to load: $e'),
            data: (items) {
              if (items.isEmpty) {
                return _emptyCard(t, 'No orphaned items.');
              }
              return Column(
                children: [
                  for (final item in items) _orphanItemTile(t, item),
                ],
              );
            },
          ),
          const SizedBox(height: 28),
          _sectionHeader(t, 'Row-count audit'),
          const SizedBox(height: 12),
          _auditCard(t),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData t, String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: t.colorScheme.primary,
          letterSpacing: 1.2,
        ),
      );

  Widget _deferredCard(ThemeData t, List<String> tables) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FontAwesomeIcons.cloudArrowDown,
                size: 16,
                color: t.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Some history is still catching up',
                style: t.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'The last full pull deferred ${tables.length} '
            'table${tables.length == 1 ? '' : 's'} because the connection '
            'was too slow to fetch them. Live activity still syncs '
            'normally. Tap retry on a stronger connection to catch the '
            'history up.',
            style: t.textTheme.bodySmall?.copyWith(
              color: t.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tbl in tables)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: t.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    tbl,
                    style: t.textTheme.bodySmall?.copyWith(
                      color: t.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: _retryingDeferred ? null : _retryDeferredPull,
              icon: _retryingDeferred
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 16),
              label: Text(_retryingDeferred ? 'Retrying…' : 'Retry pull'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _healthCard(
    ThemeData t, {
    required String? businessId,
    required JwtClaimSnapshot claims,
    required _ProfileProbe profile,
    required int pending,
    required int failed,
    required int orphaned,
  }) {
    // RLS in this project uses auth.uid() → profiles, not the JWT claim.
    // The claim status is shown for completeness only — its absence is
    // expected and harmless. Session presence is the real signal here.
    final claimColor = !claims.hasSession
        ? t.colorScheme.error
        : t.colorScheme.onSurface.withValues(alpha: 0.7);
    final claimText = !claims.hasSession
        ? 'No active Supabase session'
        : claims.error != null
            ? 'JWT decode error: ${claims.error}'
            : claims.businessId != null
                ? 'JWT business_id: ${claims.businessId} (via ${claims.source}, informational)'
                : 'JWT business_id: not present (expected — RLS uses profiles join)';

    // Profile probe: this is what `get_user_business_id()` actually returns,
    // and therefore what RLS will enforce. Mismatch with local businessId is
    // the most likely root cause of silent insert failures.
    String profileText;
    Color? profileColor;
    if (!profile.fetched) {
      profileText = 'Checking…';
    } else if (profile.error != null) {
      profileText = 'Probe failed: ${profile.error}';
      profileColor = t.colorScheme.error;
    } else if (!profile.found) {
      profileText = 'No profiles row for current auth.uid()';
      profileColor = t.colorScheme.error;
    } else if (profile.businessId == null) {
      profileText = 'profiles.business_id is NULL — RLS will reject inserts';
      profileColor = t.colorScheme.error;
    } else if (businessId != null && profile.businessId != businessId) {
      profileText =
          'profiles.business_id = ${profile.businessId} (mismatch — local is $businessId)';
      profileColor = t.colorScheme.error;
    } else {
      profileText = 'profiles.business_id = ${profile.businessId}';
      profileColor = Colors.green;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _healthRow(t, FontAwesomeIcons.idBadge, 'Local businessId',
              businessId?.toString() ?? '—'),
          const SizedBox(height: 10),
          _healthRow(t, FontAwesomeIcons.userCheck, 'Cloud profile',
              profileText,
              valueColor: profileColor),
          const SizedBox(height: 10),
          _healthRow(t, FontAwesomeIcons.key, 'JWT claim', claimText,
              valueColor: claimColor),
          const SizedBox(height: 10),
          _healthRow(t, FontAwesomeIcons.clockRotateLeft, 'Pending in queue',
              pending.toString()),
          const SizedBox(height: 10),
          _healthRow(
            t,
            FontAwesomeIcons.triangleExclamation,
            'Failed in queue',
            failed.toString(),
            valueColor: failed == 0 ? null : t.colorScheme.error,
          ),
          const SizedBox(height: 10),
          _healthRow(
            t,
            FontAwesomeIcons.ghost,
            'Orphaned (auto-archived)',
            orphaned.toString(),
            valueColor: orphaned == 0 ? null : t.colorScheme.error,
          ),
        ],
      ),
    );
  }

  Widget _healthRow(ThemeData t, IconData icon, String label, String value,
      {Color? valueColor}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: t.colorScheme.onSurface.withValues(alpha: 0.6)),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: t.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: valueColor ?? t.colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyCard(ThemeData t, String text) => Container(
        padding: const EdgeInsets.all(20),
        decoration: AppDecorations.glassCard(context, radius: 16),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: t.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      );

  Future<void> _retryAllOrphans() async {
    final dao = _db.syncDao;
    final orphans = await dao.watchOrphans().first;
    var ok = 0;
    var failed = 0;
    for (final orphan in orphans) {
      try {
        await dao.retryOrphan(orphan.id);
        ok++;
      } catch (_) {
        failed++;
      }
    }
    unawaited(_sync.pushPending());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Re-enqueued $ok orphan(s)'
          '${failed > 0 ? ', $failed could not be retried' : ''}.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _orphanItemTile(ThemeData t, SyncQueueOrphanData item) {
    final reasonText = item.reason;
    final payloadPreview = item.payload.length > 200
        ? '${item.payload.substring(0, 200)}…'
        : item.payload;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: AppDecorations.glassCard(context, radius: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: t.colorScheme.error.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Orphan',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: t.colorScheme.error,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.actionType,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.colorScheme.onSurface,
                  ),
                ),
              ),
              Text(
                'archived: ${item.movedAt.toLocal()}',
                style: TextStyle(
                  fontSize: 11,
                  color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            reasonText,
            style: TextStyle(
              fontSize: 12,
              color: t.colorScheme.error.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            payloadPreview,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: t.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: () async {
                  try {
                    await _db.syncDao.retryOrphan(item.id);
                    unawaited(_sync.pushPending());
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Re-enqueued.'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Retry failed: $e'),
                        backgroundColor: t.colorScheme.error,
                      ),
                    );
                  }
                },
                child: const Text('Retry'),
              ),
              TextButton(
                onPressed: () async {
                  await ref
                      .read(databaseProvider)
                      .syncDao
                      .discardOrphan(item.id);
                },
                style:
                    TextButton.styleFrom(foregroundColor: t.colorScheme.error),
                child: const Text('Discard'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _failedItemTile(ThemeData t, SyncQueueData item) {
    final kind = _classify(item.errorMessage);
    final kindColor = switch (kind) {
      _SyncErrorKind.rls => t.colorScheme.error,
      _SyncErrorKind.missingBusinessId => Colors.orange,
      _SyncErrorKind.duplicateKey => Colors.amber,
      _SyncErrorKind.fk => Colors.deepOrange,
      _SyncErrorKind.network => Colors.blueGrey,
      _SyncErrorKind.other => t.colorScheme.onSurface.withValues(alpha: 0.6),
    };
    final payloadPreview = item.payload.length > 200
        ? '${item.payload.substring(0, 200)}…'
        : item.payload;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: AppDecorations.glassCard(context, radius: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: kindColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _labelFor(kind),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: kindColor,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.actionType,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.colorScheme.onSurface,
                  ),
                ),
              ),
              Text(
                'attempts: ${item.attempts}',
                style: TextStyle(
                  fontSize: 11,
                  color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
          if (item.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              item.errorMessage!,
              style: TextStyle(
                fontSize: 12,
                color: t.colorScheme.error.withValues(alpha: 0.9),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            payloadPreview,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: t.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (item.nextAttemptAt != null)
                Expanded(
                  child: Text(
                    'Next try: ${item.nextAttemptAt!.toLocal()}',
                    style: TextStyle(
                      fontSize: 11,
                      color: t.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                )
              else
                const Spacer(),
              TextButton(
                onPressed: () async {
                  await _db.syncDao.clearFailureBackoffById(item.id);
                  unawaited(_sync.pushPending());
                },
                child: const Text('Retry now'),
              ),
              TextButton(
                onPressed: () async {
                  await ref
                      .read(databaseProvider)
                      .syncDao
                      .discardQueueItem(item.id);
                },
                style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
                child: const Text('Discard'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _auditCard(ThemeData t) {
    return Container(
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _auditExpanded = !_auditExpanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(FontAwesomeIcons.tableCells,
                      size: 14, color: t.colorScheme.primary),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      'Compare local vs Supabase row counts',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: t.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  Icon(
                    _auditExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ),
          if (_auditExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Authed count uses the current session (RLS applies). '
                    'Service-role count bypasses RLS — paste a key only on a '
                    'trusted dev device.',
                    style: TextStyle(
                      fontSize: 11,
                      color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _projectUrlCtl,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Project URL (optional)',
                        hintText: 'https://<ref>.supabase.co',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _serviceKeyCtl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Service role key (optional, dev only)',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _auditRunning ? null : _runAudit,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: Text(_auditRunning ? 'Running…' : 'Run audit'),
                  ),
                  const SizedBox(height: 12),
                  if (_auditResults != null) _auditTable(t, _auditResults!),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _auditTable(ThemeData t, List<TableDiagnosticRow> rows) {
    Widget cell(String text,
            {bool header = false, Color? color, TextAlign? align}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Text(
            text,
            textAlign: align,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: header ? FontWeight.w700 : FontWeight.w500,
              color: color ??
                  (header
                      ? t.colorScheme.primary
                      : t.colorScheme.onSurface.withValues(alpha: 0.85)),
              fontFamily: header ? null : 'monospace',
            ),
          ),
        );

    const colTable = 180.0;
    const colInt = 72.0;
    const colDiag = 140.0;
    const total = colTable + colInt * 3 + colDiag;

    Widget row(List<Widget> children, {Color? bg}) => Container(
          color: bg,
          height: 30,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: children,
          ),
        );

    Widget sized(double w, Widget child) => SizedBox(width: w, child: child);

    final header = row([
      sized(colTable, cell('Table', header: true)),
      sized(colInt, cell('Local', header: true, align: TextAlign.right)),
      sized(colInt, cell('Authed', header: true, align: TextAlign.right)),
      sized(colInt, cell('Service', header: true, align: TextAlign.right)),
      sized(colDiag, cell('Diagnosis', header: true)),
    ]);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: total,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            for (final r in rows)
              row([
                sized(colTable, cell(r.table)),
                sized(colInt,
                    cell(r.local?.toString() ?? '—', align: TextAlign.right)),
                sized(
                    colInt,
                    cell(r.remoteAuthed?.toString() ?? '—',
                        align: TextAlign.right)),
                sized(
                    colInt,
                    cell(r.remoteService?.toString() ?? '—',
                        align: TextAlign.right)),
                sized(
                    colDiag,
                    cell(_diagnose(r),
                        color: _diagnose(r) == 'OK'
                            ? Colors.green
                            : t.colorScheme.error)),
              ]),
          ],
        ),
      ),
    );
  }

  String _diagnose(TableDiagnosticRow r) {
    if (r.error != null) return 'ERR';
    final l = r.local;
    final a = r.remoteAuthed;
    final s = r.remoteService;
    if (l == null || a == null) return '—';
    if (s != null && a < s) return 'RLS hides ${s - a}';
    if (s != null && s < l) return 'Push gap ${l - s}';
    if (s == null && a < l) return 'Push/RLS gap ${l - a}';
    if (l == a && (s == null || s == a)) return 'OK';
    return '—';
  }
}

