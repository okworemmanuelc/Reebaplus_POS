import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// §3.1 "Resolve unsynced data" flow (Invariant #12). Surfaced when a
/// logout is blocked because the outbox holds **un-pushable** rows the cloud is
/// actively rejecting (this device's access to the business changed). The user
/// is never trapped: they EXPORT the stuck records (money recoverable on paper)
/// and then must TYPE a confirmation to discard them and complete the logout.
///
/// [photoCount] (#343) is product photos that would not upload even online.
/// They are listed in the message and deleted with the discard; a photo can't
/// go in the export, so with photos alone there is nothing to export and the
/// typed confirmation is the only step.
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
  int photoCount = 0,
  bool isResign = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ResolveUnsyncedDataDialog(
      pendingCount: pendingCount,
      orphanCount: orphanCount,
      photoCount: photoCount,
      isResign: isResign,
    ),
  );
  return result ?? false;
}

class _ResolveUnsyncedDataDialog extends ConsumerStatefulWidget {
  const _ResolveUnsyncedDataDialog({
    required this.pendingCount,
    required this.orphanCount,
    required this.photoCount,
    required this.isResign,
  });

  final int pendingCount;
  final int orphanCount;
  final int photoCount;
  final bool isResign;

  @override
  ConsumerState<_ResolveUnsyncedDataDialog> createState() =>
      _ResolveUnsyncedDataDialogState();
}

class _ResolveUnsyncedDataDialogState
    extends ConsumerState<_ResolveUnsyncedDataDialog> {
  static const _confirmWord = 'DISCARD';

  final _confirmController = TextEditingController();
  // Only outbox records can be exported; with nothing but photos there is no
  // file to make, so discard is unlocked from the start.
  late bool _hasExported = _recordCount == 0;
  bool _exporting = false;
  bool _discarding = false;

  int get _recordCount => widget.pendingCount + widget.orphanCount;
  int get _total => _recordCount + widget.photoCount;

  String get _photoPhrase =>
      '${widget.photoCount} product photo${widget.photoCount == 1 ? "" : "s"}';

  String get _discardWhat => _recordCount > 0
      ? 'these records'
      : (widget.photoCount == 1 ? 'this photo' : 'these photos');

  String get _message {
    if (_recordCount == 0) {
      return '$_photoPhrase on this device could not be uploaded. Check your '
          'internet and try again, or discard '
          '${widget.photoCount == 1 ? "it" : "them"} to finish '
          '${widget.isResign ? "leaving your account" : "logging out"}.';
    }
    final records =
        '$_recordCount change${_recordCount == 1 ? "" : "s"} on this device '
        'could not be uploaded — your access to this business changed, so '
        'the server is rejecting them. Export them first so nothing is '
        'lost, then you can finish logging out.';
    if (widget.photoCount == 0) return records;
    return '$records $_photoPhrase could not be uploaded either; '
        '${widget.photoCount == 1 ? "it" : "they"} will be deleted too.';
  }

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
      final stamp = DateTime.now()
          .toIso8601String()
          .split('.')
          .first
          .replaceAll(':', '-');
      final csv = buildCsv(const [
        'source',
        'table',
        'action',
        'row_id',
        'reason',
        'created_at',
        'payload',
      ], rows);
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
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    return AlertDialog(
      // The typed-confirmation box sits in this pop-up, so it scrolls with
      // the keyboard up (owner phone check, #402).
      scrollable: true,
      title: Text(
        _recordCount == 0
            ? 'Photos that can\'t upload'
            : 'Records that can\'t sync',
        style: context
            .extraBoldStyle(18)
            .copyWith(color: theme.colorScheme.onSurface),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _message,
            style: context
                .regularStyle(14)
                .copyWith(color: theme.colorScheme.onSurface, height: 1.4),
          ),
          if (_recordCount > 0) ...[
            SizedBox(height: context.getRSize(16)),
            AppButton(
              key: SyncKeys.resolveExport,
              text: _hasExported ? 'Exported — export again' : 'Export records',
              icon: _hasExported ? AppIcons.check : AppIcons.download,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              height: kMinInteractiveDimension,
              isLoading: _exporting,
              onPressed: _exporting ? null : _export,
            ),
          ],
          SizedBox(height: context.getRSize(16)),
          Text(
            _hasExported
                ? 'Type $_confirmWord to permanently discard $_discardWhat '
                      '${widget.isResign ? "and leave your account." : "and log out."}'
                : 'Export the records to unlock discard.',
            style: context.regularStyle(13).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(8)),
          AppInput(
            key: SyncKeys.resolveInput,
            controller: _confirmController,
            enabled: _hasExported && !_discarding,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            hintText: _confirmWord,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _discarding
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: SyncKeys.resolveDiscard,
          onPressed: _canDiscard ? _discardAndLogout : null,
          style: FilledButton.styleFrom(
            backgroundColor: f.danger,
            foregroundColor: f.onSolid,
            minimumSize: const Size(
              kMinInteractiveDimension,
              kMinInteractiveDimension,
            ),
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
