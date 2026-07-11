import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// §3.1 "Resolve unsynced data" flow (Invariant #12). Surfaced when a sole-user
/// logout is blocked because the outbox holds **un-pushable** rows the cloud is
/// actively rejecting (this device's access to the business changed). The user
/// is never trapped: they EXPORT the stuck records (money recoverable on paper)
/// and then must TYPE a confirmation to discard them and complete the logout.
///
/// Returns `true` if the user discarded + logged out (the caller should treat
/// the session as gone), `false` if they cancelled.
///
/// [isResign] switches the terminal action from a plain logout
/// ([AuthService.discardUnsyncedAndLogout]) to a self-resign
/// ([AuthService.discardUnsyncedAndResign], #117), which additionally detaches
/// the caller's membership server-side (frees their email). Same export → typed
/// discard UX; only the confirmed terminal + button copy differ.
Future<bool> showResolveUnsyncedDataDialog(
  BuildContext context,
  WidgetRef ref, {
  required int pendingCount,
  required int orphanCount,
  bool isResign = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ResolveUnsyncedDataDialog(
      pendingCount: pendingCount,
      orphanCount: orphanCount,
      isResign: isResign,
    ),
  );
  return result ?? false;
}

class _ResolveUnsyncedDataDialog extends ConsumerStatefulWidget {
  const _ResolveUnsyncedDataDialog({
    required this.pendingCount,
    required this.orphanCount,
    required this.isResign,
  });

  final int pendingCount;
  final int orphanCount;
  final bool isResign;

  @override
  ConsumerState<_ResolveUnsyncedDataDialog> createState() =>
      _ResolveUnsyncedDataDialogState();
}

class _ResolveUnsyncedDataDialogState
    extends ConsumerState<_ResolveUnsyncedDataDialog> {
  static const _confirmWord = 'DISCARD';

  final _confirmController = TextEditingController();
  bool _hasExported = false;
  bool _exporting = false;
  bool _discarding = false;

  int get _total => widget.pendingCount + widget.orphanCount;
  bool get _canDiscard =>
      _hasExported &&
      !_discarding &&
      _confirmController.text.trim().toUpperCase() == _confirmWord;

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final auth = ref.read(authProvider);
      final db = ref.read(databaseProvider);
      final user = auth.currentUser;
      if (user == null) return;
      final rows = await db.syncDao.unsyncedExportRows(user.businessId);
      final stamp = DateTime.now().toIso8601String().split('.').first
          .replaceAll(':', '-');
      final csv = buildCsv(
        const ['source', 'table', 'action', 'row_id', 'reason', 'created_at',
            'payload'],
        rows,
      );
      await shareCsv(
        csv: csv,
        fileName: 'unsynced-records-$stamp',
        subject: 'Unsynced records ($_total) before logout',
      );
      if (mounted) setState(() => _hasExported = true);
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Could not export records: $e');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _discardAndLogout() async {
    setState(() => _discarding = true);
    try {
      final auth = ref.read(authProvider);
      if (widget.isResign) {
        await auth.discardUnsyncedAndResign();
      } else {
        await auth.discardUnsyncedAndLogout();
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _discarding = false);
        AppNotification.showError(
          context,
          widget.isResign
              ? 'Could not leave your account: $e'
              : 'Could not complete logout: $e',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Records that can\'t sync'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$_total change${_total == 1 ? "" : "s"} on this device '
              'could not be uploaded — your access to this business changed, so '
              'the server is rejecting them. Export them first so nothing is '
              'lost, then you can finish logging out.',
              style: theme.textTheme.bodyMedium,
            ),
            SizedBox(height: context.getRSize(16)),
            FilledButton.tonalIcon(
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? SizedBox(
                      width: context.getRSize(16),
                      height: context.getRSize(16),
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _hasExported ? Icons.check : Icons.download_outlined,
                    ),
              label: Text(_hasExported ? 'Exported — export again' : 'Export records'),
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              _hasExported
                  ? 'Type $_confirmWord to permanently discard these records '
                      '${widget.isResign ? "and leave your account." : "and log out."}'
                  : 'Export the records to unlock discard.',
              style: theme.textTheme.bodySmall,
            ),
            SizedBox(height: context.getRSize(8)),
            TextField(
              controller: _confirmController,
              enabled: _hasExported && !_discarding,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                hintText: _confirmWord,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _discarding ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canDiscard ? _discardAndLogout : null,
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
          ),
          child: _discarding
              ? SizedBox(
                  width: context.getRSize(18),
                  height: context.getRSize(18),
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.isResign ? 'Discard & leave' : 'Discard & log out'),
        ),
      ],
    );
  }
}
