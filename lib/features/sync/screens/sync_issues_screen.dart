import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/diagnostics/sync_diagnostic.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

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

enum _SyncErrorKind {
  rls,
  missingBusinessId,
  authUserMismatch,
  duplicateKey,
  fk,
  network,
  other,
}

_SyncErrorKind _classify(String? error) {
  if (error == null) return _SyncErrorKind.other;
  final e = error.toLowerCase();
  if (e == 'missing_business_id') return _SyncErrorKind.missingBusinessId;
  if (e.startsWith('auth_user_mismatch')) {
    return _SyncErrorKind.authUserMismatch;
  }
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
    case _SyncErrorKind.authUserMismatch:
      return 'Wrong user';
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
    final raw = prefs.getString(
      SupabaseSyncService.pendingDeferredTablesKey(businessId),
    );
    if (!mounted) return;
    setState(() {
      _deferredTables = (raw == null || raw.isEmpty)
          ? const []
          : raw
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Re-sync complete.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Re-sync failed: $e')));
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
      if (mounted) {
        setState(() => _profile = const _ProfileProbe.failed('no session'));
      }
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
      if (mounted) {
        setState(() => _profile = _ProfileProbe.failed(e.toString()));
      }
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
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    // Defense-in-depth (hard rules #6/#7): body-guard on Gates.viewSyncIssues
    // (sync.view OR CEO — the implicit owner; other roles get it via CEO
    // Settings → Sync Issues access), the same entry the sidebar item and the
    // drawer sync badge/banner already hide on. This guards a deep-link /
    // direct push. Keep the top bar so the back button still works.
    if (!Gates.viewSyncIssues.allows(ref)) {
      return Container(
        decoration: AppDecorations.pageBackground(context),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: SyncTopBar.of(context, title: 'Sync Issues'),
          body: Center(
            key: SyncKeys.noAccess,
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(16)),
              child: Text(
                'You don\'t have access to Sync Issues.',
                textAlign: TextAlign.center,
                style: context.regularStyle(14).copyWith(color: muted),
              ),
            ),
          ),
        ),
      );
    }
    final pendingAsync = ref.watch(pendingQueueItemsProvider);
    final failedAsync = ref.watch(failedQueueItemsProvider);
    final orphanAsync = ref.watch(orphanQueueItemsProvider);
    final pendingCount = ref.watch(pendingQueueCountProvider).valueOrNull ?? 0;
    final failedCount = ref.watch(failedQueueCountProvider).valueOrNull ?? 0;
    final orphanCount = ref.watch(orphanQueueCountProvider).valueOrNull ?? 0;
    final claims = SupabaseSyncService.inspectJwtClaims();
    final businessId = ref.read(authProvider).currentUser?.businessId;

    Widget loading() => Padding(
      padding: EdgeInsets.all(context.getRSize(24)),
      child: const Center(child: CircularProgressIndicator()),
    );
    Widget section(String title) => SectionHeader(title: title);
    final sectionGap = SizedBox(height: context.getRSize(24));
    final headerGap = SizedBox(height: context.getRSize(10));

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        // Body padding is nav-only (deviceBottomPadding): this screen is under
        // MainLayout, whose Scaffold already resizes the body for the keyboard,
        // so the inset must not re-add it. resizeToAvoidBottomInset:false is a
        // harmless no-op here (the screen sees viewInsets 0 under MainLayout).
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.transparent,
        appBar: SyncTopBar.of(context, title: 'Sync Issues'),
        body: SafeArea(
          top: false,
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gutter = syncGutter(context, constraints.maxWidth);
              return ListView(
                key: SyncKeys.list,
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  context.getRSize(16),
                  gutter,
                  context.getRSize(16) + context.deviceBottomPadding,
                ),
                children: [
                  section('Health'),
                  headerGap,
                  _healthCard(
                    t,
                    businessId: businessId,
                    claims: claims,
                    profile: _profile,
                    pending: pendingCount,
                    failed: failedCount,
                    orphaned: orphanCount,
                  ),
                  sectionGap,
                  if (_deferredTables.isNotEmpty) ...[
                    section('Catching up'),
                    headerGap,
                    _deferredCard(t, _deferredTables),
                    sectionGap,
                  ],
                  section('Pending items'),
                  SizedBox(height: context.getRSize(4)),
                  const SyncHint(
                    'Queued for push. If a row sits here for more than a few '
                    'minutes, tap Retry now to force a fresh attempt or '
                    'Discard to drop it.',
                  ),
                  headerGap,
                  pendingAsync.when(
                    loading: loading,
                    error: (e, _) => SyncMessageCard('Failed to load: $e'),
                    data: (items) {
                      if (items.isEmpty) {
                        return const SyncMessageCard('No pending items.');
                      }
                      return Column(
                        children: [
                          for (final item in items) _pendingItemTile(t, item),
                        ],
                      );
                    },
                  ),
                  sectionGap,
                  section('Failed items'),
                  headerGap,
                  failedAsync.when(
                    loading: loading,
                    error: (e, _) => SyncMessageCard('Failed to load: $e'),
                    data: (items) {
                      if (items.isEmpty) {
                        return const SyncMessageCard('No failed items.');
                      }
                      return Column(
                        children: [
                          for (final item in items) _failedItemTile(t, item),
                        ],
                      );
                    },
                  ),
                  sectionGap,
                  Row(
                    children: [
                      Expanded(child: section('Orphaned items')),
                      if (orphanCount > 0)
                        SyncAction(
                          key: SyncKeys.retryAllOrphans,
                          text: 'Retry all',
                          onPressed: () => _retryAllOrphans(),
                        ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(4)),
                  const SyncHint(
                    'Permanent failures auto-archived out of the queue. '
                    'Surface here so a "Push/RLS gap" in the audit below has '
                    'a visible cause.',
                  ),
                  headerGap,
                  orphanAsync.when(
                    loading: loading,
                    error: (e, _) => SyncMessageCard('Failed to load: $e'),
                    data: (items) {
                      if (items.isEmpty) {
                        return const SyncMessageCard('No orphaned items.');
                      }
                      return Column(
                        children: [
                          for (final item in items) _orphanItemTile(t, item),
                        ],
                      );
                    },
                  ),
                  sectionGap,
                  section('Row-count audit'),
                  headerGap,
                  _auditCard(t),
                  SizedBox(height: context.getRSize(8)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _deferredCard(ThemeData t, List<String> tables) {
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return SyncCard(
      key: SyncKeys.deferredCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.download,
                size: context.getRSize(18),
                color: t.colorScheme.primary,
              ),
              SizedBox(width: context.getRSize(8)),
              Expanded(
                child: Text(
                  'Some history is still catching up',
                  style: context
                      .boldStyle(15)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            'The last pull held back ${tables.length} '
            'table${tables.length == 1 ? '' : 's'} — either the connection was '
            'too slow to fetch them, or they reference a record (usually an '
            'order) that has not arrived on this device yet. Live activity '
            'still syncs normally. Tap retry on a stronger connection; if it '
            'keeps coming back, the app is healing it in the background and it '
            'should clear within a sync or two.',
            style: context.regularStyle(13).copyWith(color: muted, height: 1.4),
          ),
          SizedBox(height: context.getRSize(12)),
          Wrap(
            spacing: context.getRSize(6),
            runSpacing: context.getRSize(6),
            children: [for (final tbl in tables) TagPill(label: tbl)],
          ),
          SizedBox(height: context.getRSize(12)),
          Align(
            alignment: Alignment.centerRight,
            child: SyncAction(
              key: SyncKeys.retryPull,
              text: _retryingDeferred ? 'Retrying…' : 'Retry pull',
              icon: AppIcons.refresh,
              isLoading: _retryingDeferred,
              onPressed: _retryingDeferred ? null : _retryDeferredPull,
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
    final claimTone = !claims.hasSession
        ? SyncFactTone.bad
        : SyncFactTone.normal;
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
    var profileTone = SyncFactTone.normal;
    if (!profile.fetched) {
      profileText = 'Checking…';
    } else if (profile.error != null) {
      profileText = 'Probe failed: ${profile.error}';
      profileTone = SyncFactTone.bad;
    } else if (!profile.found) {
      profileText = 'No profiles row for current auth.uid()';
      profileTone = SyncFactTone.bad;
    } else if (profile.businessId == null) {
      profileText = 'profiles.business_id is NULL — RLS will reject inserts';
      profileTone = SyncFactTone.bad;
    } else if (businessId != null && profile.businessId != businessId) {
      profileText =
          'profiles.business_id = ${profile.businessId} (mismatch — local is $businessId)';
      profileTone = SyncFactTone.bad;
    } else {
      profileText = 'profiles.business_id = ${profile.businessId}';
      profileTone = SyncFactTone.ok;
    }

    final gap = SizedBox(height: context.getRSize(10));
    return SyncCard(
      key: SyncKeys.healthCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SyncFactRow(
            icon: AppIcons.idBadge,
            label: 'Local businessId',
            value: businessId?.toString() ?? '—',
          ),
          gap,
          SyncFactRow(
            icon: AppIcons.userVerified,
            label: 'Cloud profile',
            value: profileText,
            tone: profileTone,
          ),
          gap,
          SyncFactRow(
            icon: AppIcons.key,
            label: 'JWT claim',
            value: claimText,
            tone: claimTone,
          ),
          gap,
          SyncFactRow(
            icon: AppIcons.history,
            label: 'Pending in queue',
            value: pending.toString(),
          ),
          gap,
          SyncFactRow(
            icon: AppIcons.warning,
            label: 'Failed in queue',
            value: failed.toString(),
            tone: failed == 0 ? SyncFactTone.normal : SyncFactTone.bad,
          ),
          gap,
          SyncFactRow(
            icon: AppIcons.ghost,
            label: 'Orphaned (auto-archived)',
            value: orphaned.toString(),
            tone: orphaned == 0 ? SyncFactTone.normal : SyncFactTone.bad,
          ),
        ],
      ),
    );
  }

  /// The pill tone for a classified error: reds for access problems, amber for
  /// data conflicts, neutral for transport and the unknown.
  TagPillTone _toneFor(_SyncErrorKind kind) => switch (kind) {
    _SyncErrorKind.rls => TagPillTone.danger,
    _SyncErrorKind.authUserMismatch => TagPillTone.danger,
    _SyncErrorKind.missingBusinessId => TagPillTone.warning,
    _SyncErrorKind.duplicateKey => TagPillTone.warning,
    _SyncErrorKind.fk => TagPillTone.warning,
    _SyncErrorKind.network => TagPillTone.neutral,
    _SyncErrorKind.other => TagPillTone.neutral,
  };

  String _preview(String payload) =>
      payload.length > 200 ? '${payload.substring(0, 200)}…' : payload;

  Future<void> _retryItem(SyncQueueData item) async {
    try {
      await _db.syncDao.clearFailureBackoffById(item.id);
      unawaited(_sync.pushPending());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not retry item: $e')));
    }
  }

  Future<void> _discardItem(SyncQueueData item) async {
    try {
      await ref.read(databaseProvider).syncDao.discardQueueItem(item.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not discard item: $e')));
    }
  }

  List<Widget> _queueActions(SyncQueueData item) => [
    SyncAction(
      key: SyncKeys.retryItem(item.id),
      text: 'Retry now',
      onPressed: () => _retryItem(item),
    ),
    SyncAction(
      key: SyncKeys.discardItem(item.id),
      text: 'Discard',
      variant: AppButtonVariant.danger,
      onPressed: () => _discardItem(item),
    ),
  ];

  Widget _orphanItemTile(ThemeData t, SyncQueueOrphanData item) {
    // A rejected `pos_record_sale_v2` sale (an oversell the cloud rolled back)
    // gets a one-tap recovery: run the same full local reversal as the
    // `sale_rejected` notification, then clear this orphan (#150).
    final rejectedOrderId = _rejectedSaleOrderId(item);

    return SyncItemCard(
      key: SyncKeys.orphanItem(item.id),
      pillLabel: 'Orphan',
      pillTone: TagPillTone.danger,
      actionType: item.actionType,
      meta: 'archived: ${item.movedAt.toLocal()}',
      errorText: item.reason,
      payloadPreview: _preview(item.payload),
      actions: [
        if (rejectedOrderId != null)
          SyncAction(
            text: 'Cancel this sale',
            variant: AppButtonVariant.outline,
            onPressed: () => _confirmCancelRejectedSale(item, rejectedOrderId),
          ),
        SyncAction(
          key: SyncKeys.retryItem(item.id),
          text: 'Retry',
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
        ),
        SyncAction(
          key: SyncKeys.discardItem(item.id),
          text: 'Discard',
          variant: AppButtonVariant.danger,
          onPressed: () async {
            try {
              await ref.read(databaseProvider).syncDao.discardOrphan(item.id);
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Could not discard orphan: $e')),
              );
            }
          },
        ),
      ],
    );
  }

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

  /// The plain `p_order_id` of a rejected-sale orphan
  /// (`domain:pos_record_sale_v2`), or null for any other orphan or an
  /// unparseable payload. Drives the one-tap "Cancel this sale" recovery (#150).
  String? _rejectedSaleOrderId(SyncQueueOrphanData item) {
    if (item.actionType != 'domain:pos_record_sale_v2') return null;
    try {
      final decoded = jsonDecode(item.payload);
      if (decoded is Map) {
        final oid = decoded['p_order_id'];
        if (oid is String && oid.isNotEmpty) return oid;
      }
    } catch (_) {
      // Unparseable payload — no recovery affordance.
    }
    return null;
  }

  /// Confirms and runs the second recovery entry point for a server-rejected
  /// sale (#150): the SAME full local reversal the `sale_rejected` notification
  /// runs — order + inventory + wallet + crate — sourced from this orphan's
  /// `p_items`, then the orphan is cleared. The reversal runs BEFORE the orphan
  /// is discarded (it reads the payload), so it is never discard-then-recover.
  Future<void> _confirmCancelRejectedSale(
    SyncQueueOrphanData item,
    String orderId,
  ) async {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    // Resolve everything off `ref` before any await — the element can unmount
    // while the dialog is open, and touching `ref` afterwards races the
    // riverpod invalidation (see the initState capture note above).
    final staffId = ref.read(authProvider).currentUser?.id;
    final orderService = ref.read(orderServiceProvider);
    if (staffId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please sign in again to cancel this sale.'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(
          'Cancel this rejected sale?',
          style: ctx
              .extraBoldStyle(18)
              .copyWith(color: t.colorScheme.onSurface),
        ),
        content: Text(
          'The server turned this sale down — the item was likely sold on '
          'another till. Cancelling removes the sale from this device: the '
          'stock and any customer empties balance go back to what they were '
          'before it, and this entry is cleared.',
          style: ctx
              .regularStyle(14)
              .copyWith(color: t.colorScheme.onSurface, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: f.danger),
            child: const Text('Cancel the sale'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await orderService.cancelRejectedSaleFromOrphan(
        orderId: orderId,
        orphanId: item.id,
        staffId: staffId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sale cancelled. Stock and balances restored.'),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (_) {
      // Mirror the notification path: show a friendly generic message rather
      // than a raw exception string to a cashier.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not cancel the sale. Please try again.'),
          backgroundColor: t.colorScheme.error,
        ),
      );
    }
  }

  Widget _pendingItemTile(ThemeData t, SyncQueueData item) {
    final hasError = item.errorMessage != null;
    final kind = _classify(item.errorMessage);
    final nextAttemptLabel = item.nextAttemptAt == null
        ? 'Next try: ASAP'
        : 'Next try: ${item.nextAttemptAt!.toLocal()}';

    return SyncItemCard(
      key: SyncKeys.pendingItem(item.id),
      pillLabel: hasError ? _labelFor(kind) : 'Pending',
      pillTone: hasError ? _toneFor(kind) : TagPillTone.info,
      actionType: item.actionType,
      meta: 'attempts: ${item.attempts}',
      errorText: item.errorMessage,
      detailLines: [nextAttemptLabel],
      payloadPreview: _preview(item.payload),
      actions: _queueActions(item),
    );
  }

  Widget _failedItemTile(ThemeData t, SyncQueueData item) {
    final kind = _classify(item.errorMessage);
    return SyncItemCard(
      key: SyncKeys.failedItem(item.id),
      pillLabel: _labelFor(kind),
      pillTone: _toneFor(kind),
      actionType: item.actionType,
      meta: 'attempts: ${item.attempts}',
      errorText: item.errorMessage,
      detailLines: [
        if (item.nextAttemptAt != null)
          'Next try: ${item.nextAttemptAt!.toLocal()}',
      ],
      payloadPreview: _preview(item.payload),
      actions: _queueActions(item),
    );
  }

  Widget _auditCard(ThemeData t) {
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return SyncCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: SyncKeys.auditToggle,
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
            onTap: () => setState(() => _auditExpanded = !_auditExpanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Padding(
                padding: EdgeInsets.all(context.getRSize(14)),
                child: Row(
                  children: [
                    AppIcon(
                      AppIcons.table,
                      size: context.getRSize(18),
                      color: t.colorScheme.primary,
                    ),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      child: Text(
                        'Compare local vs Supabase row counts',
                        style: context
                            .boldStyle(14)
                            .copyWith(color: t.colorScheme.onSurface),
                      ),
                    ),
                    AppIcon(
                      _auditExpanded
                          ? AppIcons.chevronUp
                          : AppIcons.chevronDown,
                      size: context.getRSize(22),
                      color: muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_auditExpanded)
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(14),
                0,
                context.getRSize(14),
                context.getRSize(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SyncHint(
                    'Authed count uses the current session (RLS applies). '
                    'Service-role count bypasses RLS — paste a key only on a '
                    'trusted dev device.',
                  ),
                  if (kDebugMode) ...[
                    SizedBox(height: context.getRSize(12)),
                    AppInput(
                      key: SyncKeys.projectUrl,
                      controller: _projectUrlCtl,
                      labelText: 'Project URL (optional)',
                      hintText: 'https://<ref>.supabase.co',
                    ),
                    SizedBox(height: context.getRSize(10)),
                    AppInput(
                      key: SyncKeys.serviceKey,
                      controller: _serviceKeyCtl,
                      obscureText: true,
                      labelText: 'Service role key (optional, dev only)',
                    ),
                  ],
                  SizedBox(height: context.getRSize(12)),
                  SyncAction(
                    key: SyncKeys.runAudit,
                    text: _auditRunning ? 'Running…' : 'Run audit',
                    icon: AppIcons.play,
                    variant: AppButtonVariant.primary,
                    onPressed: _auditRunning ? null : _runAudit,
                  ),
                  SizedBox(height: context.getRSize(12)),
                  if (_auditResults != null) _auditTable(t, _auditResults!),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _auditTable(ThemeData t, List<TableDiagnosticRow> rows) {
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    Widget cell(
      String text, {
      bool header = false,
      Color? color,
      TextAlign? align,
    }) => Padding(
      padding: EdgeInsets.symmetric(
        vertical: context.getRSize(6),
        horizontal: context.getRSize(4),
      ),
      child: Text(
        text,
        textAlign: align,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: header
            ? context.boldStyle(12).copyWith(color: t.colorScheme.primary)
            : context.monoStyle.copyWith(
                fontSize: context.getRFontSize(12),
                color: color ?? t.colorScheme.onSurface,
              ),
      ),
    );

    final colTable = context.getRSize(180);
    final colInt = context.getRSize(72);
    final colDiag = context.getRSize(140);
    final total = colTable + colInt * 3 + colDiag;

    Widget row(List<Widget> children) =>
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: children);

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
                sized(
                  colInt,
                  cell(r.local?.toString() ?? '—', align: TextAlign.right),
                ),
                sized(
                  colInt,
                  cell(
                    r.remoteAuthed?.toString() ?? '—',
                    align: TextAlign.right,
                  ),
                ),
                sized(
                  colInt,
                  cell(
                    r.remoteService?.toString() ?? '—',
                    align: TextAlign.right,
                  ),
                ),
                sized(
                  colDiag,
                  cell(
                    _diagnose(r),
                    color: _diagnose(r) == 'OK' ? f.green : f.danger,
                  ),
                ),
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
