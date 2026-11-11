import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/first_load_marker_service.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_parts.dart';

/// What the Download card says, derived from the live [PullStatus] and whether
/// this phone has ever finished its first full download (#643). Pure, so it can
/// be tested without a widget tree.
class DownloadCardInfo {
  const DownloadCardInfo({
    required this.title,
    required this.lines,
    this.tone = SyncFactTone.normal,
    this.progress,
    this.busy = false,
  });

  final String title;
  final List<String> lines;
  final SyncFactTone tone;

  /// 0..1 while rows are being saved; null = indeterminate (or not running).
  final double? progress;

  /// True while a download is running (shows the progress bar).
  final bool busy;
}

/// Whole-number percentage for a running download, or null when the total is
/// unknown (0 or null) so the bar stays indeterminate. Capped at 99 while the
/// download is still running (totals can grow); 100 only when [finished].
int? downloadPercent(int? rowsDone, int? rowsTotal, {bool finished = false}) {
  if (finished) return 100;
  if (rowsTotal == null || rowsTotal <= 0) return null;
  final done = (rowsDone ?? 0).clamp(0, rowsTotal);
  return ((done * 100) ~/ rowsTotal).clamp(0, 99);
}

/// Never goes backwards within one download: the higher of what was shown and
/// the new value. Null new value keeps the held one.
int? holdPercent(int? held, int? next) {
  if (next == null) return held;
  if (held == null) return next;
  return next > held ? next : held;
}

/// A table name in words a shop owner can read ("order_items" -> "order items").
String friendlyTableName(String table) => table.replaceAll('_', ' ');

/// A failure reason with no raw error text: names only the tables for a partial
/// pull, and otherwise a plain sentence.
String friendlyFailure(String? raw) {
  final r = raw ?? '';
  if (r.startsWith('PartialPullException')) {
    final i = r.indexOf('failed: ');
    if (i >= 0) {
      final tables = r
          .substring(i + 'failed: '.length)
          .split(',')
          .map((s) => friendlyTableName(s.trim()))
          .where((s) => s.isNotEmpty)
          .join(', ');
      if (tables.isNotEmpty) {
        return "Couldn't fetch: $tables. The app will try again.";
      }
    }
    return "Some data couldn't be fetched. The app will try again.";
  }
  final l = r.toLowerCase();
  if (l.contains('socketexception') ||
      l.contains('timeoutexception') ||
      l.contains('clientexception')) {
    return 'The connection dropped or was too slow. The app will try again.';
  }
  return 'The download stopped. The app will try again.';
}

DownloadCardInfo describeDownload(
  PullStatus status, {
  required bool firstPullDone,
}) {
  switch (status.stage) {
    case PullStage.minimum:
    case PullStage.background:
      final lines = <String>[];
      double? progress;
      if (status.rowsTotal > 0) {
        lines.add(
          'Saving ${status.rowsDone} of ${status.rowsTotal} rows to this phone',
        );
        progress = (status.rowsDone / status.rowsTotal).clamp(0.0, 1.0);
        if (status.tablesTotal > 0) {
          lines.add('${status.tablesDone} of ${status.tablesTotal} lists saved');
        }
      } else if (status.currentTable != null) {
        lines.add(
          'Fetching ${friendlyTableName(status.currentTable!)}: '
          '${status.rowsFetched} rows fetched so far',
        );
      } else {
        lines.add('Starting the download…');
      }
      if (!firstPullDone) lines.add('Not fully downloaded yet.');
      return DownloadCardInfo(
        title: 'Downloading your data',
        lines: lines,
        progress: progress,
        busy: true,
      );
    case PullStage.failed:
      return DownloadCardInfo(
        title: 'Download stopped',
        lines: [
          friendlyFailure(status.failedReason),
          if (!firstPullDone) 'Not fully downloaded yet.',
        ],
        tone: SyncFactTone.bad,
      );
    case PullStage.idle:
    case PullStage.completed:
      if (!firstPullDone) {
        return const DownloadCardInfo(
          title: 'Not fully downloaded',
          lines: [
            "This phone hasn't finished its first full download yet. Some "
                'products, customers or history may be missing until it does.',
          ],
          tone: SyncFactTone.bad,
        );
      }
      return const DownloadCardInfo(
        title: 'Downloaded',
        lines: ['The first full download to this phone has finished.'],
        tone: SyncFactTone.ok,
      );
  }
}

/// The "Download" card on Sync Issues: the real state of the cloud-to-phone
/// download, so the screen never reads as all clear while it is unfinished.
/// Rebuilds only itself on progress updates.
class SyncDownloadCard extends ConsumerStatefulWidget {
  const SyncDownloadCard({super.key, required this.businessId});

  final String? businessId;

  static const Key cardKey = ValueKey<String>('sync-download-card');
  static const Key percentKey = ValueKey<String>('sync-download-percent');

  @override
  ConsumerState<SyncDownloadCard> createState() => _SyncDownloadCardState();
}

class _SyncDownloadCardState extends ConsumerState<SyncDownloadCard> {
  bool _firstPullDone = false;
  PullStage? _lastStage;
  int? _heldPercent;
  PullStage? _heldStage;
  int _lastRowsDone = 0;

  @override
  void initState() {
    super.initState();
    _loadMarker();
  }

  Future<void> _loadMarker() async {
    final id = widget.businessId;
    if (id == null) return;
    final done = await FirstLoadMarkerService.hasCompletedPull(id);
    if (mounted && done != _firstPullDone) {
      setState(() => _firstPullDone = done);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.watch(pullStatusProvider);
    final t = Theme.of(context);
    return ValueListenableBuilder<PullStatus>(
      valueListenable: notifier,
      builder: (context, status, _) {
        // The marker is written when a clean pull finishes; re-read it then.
        if (status.stage != _lastStage) {
          if (status.stage == PullStage.completed) _loadMarker();
          _lastStage = status.stage;
        }
        final info = describeDownload(status, firstPullDone: _firstPullDone);
        if (info.busy) {
          // The held value belongs to ONE pull: a new stage, or rows saved
          // dropping, means a new pull started.
          if (status.stage != _heldStage || status.rowsDone < _lastRowsDone) {
            _heldPercent = null;
          }
          _heldStage = status.stage;
          _lastRowsDone = status.rowsDone;
          _heldPercent = holdPercent(
            _heldPercent,
            downloadPercent(status.rowsDone, status.rowsTotal),
          );
        } else {
          _heldPercent = null;
          _heldStage = null;
          _lastRowsDone = 0;
        }
        final percent = info.busy ? _heldPercent : null;
        final icon = info.tone == SyncFactTone.bad
            ? AppIcons.warning
            : AppIcons.download;
        return SyncCard(
          key: SyncDownloadCard.cardKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SyncFactRow(
                icon: icon,
                label: info.title,
                value: info.lines.join('\n'),
                tone: info.tone,
              ),
              if (info.busy) ...[
                const SizedBox(height: 12),
                if (percent != null)
                  Padding(
                    padding: EdgeInsets.only(bottom: context.getRSize(6)),
                    child: Text(
                      '$percent%',
                      key: SyncDownloadCard.percentKey,
                      style: context.mediumStyle(13),
                    ),
                  ),
                Semantics(
                  label: percent == null
                      ? 'Download progress'
                      : 'Download progress $percent percent',
                  child: LinearProgressIndicator(
                    value: percent == null ? null : percent / 100,
                    color: t.colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
