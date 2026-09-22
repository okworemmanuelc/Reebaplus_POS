import 'package:flutter/material.dart';

import 'package:reebaplus_pos/shared/services/auth_service.dart';

/// The one-tap warning shown at sign-in when this phone still holds an older
/// business whose work has not reached the cloud (#285 decision 3).
///
/// One tap clears and continues; Cancel abandons the sign-in and leaves the
/// phone exactly as it was found. There is deliberately no export and no typed
/// DISCARD here — the logout flow's "Resolve unsynced data" path owns that
/// heavier ceremony; this is a different person signing in to a different
/// business on a phone that was never theirs.
///
/// Returns a [StaleBusinessConfirm] bound to [context], ready to hand to
/// `resolvePostVerifyRoute`.
StaleBusinessConfirm staleBusinessClearPrompt(BuildContext context) {
  return (warning) async {
    if (!context.mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear the old business from this phone?'),
        // "changes", not "sales": the count is every un-uploaded outbox row
        // for that business — a price edit, a stock count or an expense counts
        // the same as a sale, and naming them all sales would misstate what is
        // about to go.
        content: Text(
          '${warning.unsentCount} unsaved '
          '${warning.unsentCount == 1 ? 'change' : 'changes'} from '
          '${warning.businessName} will be deleted from this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear and continue'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  };
}
