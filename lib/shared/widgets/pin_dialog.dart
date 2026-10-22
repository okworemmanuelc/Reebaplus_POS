import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Shows a PIN-entry dialog that requires a user with [minimumTier] or above.
///
/// Returns the matching [UserData] when authorised, or `null` if the user
/// cancelled or entered a PIN that doesn't meet the required tier.
///
/// Usage:
/// ```dart
/// final approver = await PinDialog.show(context);
/// if (approver == null) return; // cancelled or wrong PIN
/// // ... proceed with the protected action
/// ```
class PinDialog extends ConsumerStatefulWidget {
  /// Minimum role tier needed to pass.
  /// 1 = Staff, 4 = Manager (default), 5 = CEO.
  final int minimumTier;

  /// Heading shown at the top of the dialog.
  final String title;

  const PinDialog({
    super.key,
    this.minimumTier = 4,
    this.title = 'Manager Authorisation',
  });

  /// Convenience method — call this instead of showing the widget directly.
  static Future<UserData?> show(
    BuildContext context, {
    int minimumTier = 4,
    String title = 'Manager Authorisation',
  }) {
    return showDialog<UserData?>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PinDialog(minimumTier: minimumTier, title: title),
    );
  }

  @override
  ConsumerState<PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends ConsumerState<PinDialog> {
  String _pin = '';
  String? _errorMessage;
  bool _checking = false;

  void _onDigit(String digit) {
    if (_pin.length >= 6 || _checking) return;
    setState(() {
      _pin += digit;
      _errorMessage = null;
    });
    if (_pin.length == 6) _submit();
  }

  void _onBackspace() {
    if (_pin.isEmpty || _checking) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _errorMessage = null;
    });
  }

  Future<void> _submit() async {
    setState(() => _checking = true);

    try {
      final auth = ref.read(authProvider);
      final authorised = await auth.verifyPinForTier(_pin, widget.minimumTier);

      if (!mounted) return;

      if (!authorised) {
        setState(() {
          _pin = '';
          _errorMessage = 'Wrong PIN or insufficient access.';
          _checking = false;
        });
        return;
      }

      // PIN matched — return the first matching user (lone owner setup).
      final matches = await auth.getUsersByPin(_pin);
      if (!mounted) return;

      final approved = matches.first;
      Navigator.pop(context, approved);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pin = '';
        _errorMessage = 'Something went wrong. Try again.';
        _checking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final textColor = t.colorScheme.onSurface;
    final subtextColor = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;

    // Same pop-up look as the other restyled dialogs: the theme's surface and
    // radius, DM Sans titles. The body scrolls, so a short or sideways screen
    // (or a large text size) never overflows.
    return Dialog(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(24),
          context.getRSize(24),
          context.getRSize(24),
          context.getRSize(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Title ───────────────────────────────────────────────────
            Text(
              widget.title,
              style: context.extraBoldStyle(18).copyWith(color: textColor),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              'Enter a 6-digit manager PIN to continue',
              style: context.regularStyle(13).copyWith(color: subtextColor),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: context.getRSize(20)),

            // ── Six dots ─────────────────────────────────────────────────
            PinDots(filled: _pin.length),
            SizedBox(height: context.getRSize(8)),

            // ── Error message ────────────────────────────────────────────
            SizedBox(
              height: context.getRSize(20),
              child: _errorMessage != null
                  ? Text(
                      _errorMessage!,
                      style: context.mediumStyle(12).copyWith(color: f.danger),
                      textAlign: TextAlign.center,
                    )
                  : null,
            ),
            SizedBox(height: context.getRSize(8)),

            // ── Keypad ───────────────────────────────────────────────────
            PinKeypad(onDigit: _onDigit, onBackspace: _onBackspace),

            SizedBox(height: context.getRSize(12)),

            // ── Cancel ───────────────────────────────────────────────────
            if (_checking)
              SizedBox(
                height: context.getRSize(24),
                width: context.getRSize(24),
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            else
              AppButton(
                text: 'Cancel',
                variant: AppButtonVariant.ghost,
                isFullWidth: false,
                onPressed: () => Navigator.pop(context, null),
              ),
          ],
        ),
      ),
    );
  }
}
