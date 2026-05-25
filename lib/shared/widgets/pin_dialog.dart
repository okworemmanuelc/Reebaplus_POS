import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final surface = t.colorScheme.surface;
    final cardCol = t.cardColor;
    final textColor = t.colorScheme.onSurface;
    final subtextColor = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final primary = t.colorScheme.primary;

    return Dialog(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Title ───────────────────────────────────────────────────
            Text(
              widget.title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Enter a 6-digit manager PIN to continue',
              style: TextStyle(fontSize: 12, color: subtextColor),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),

            // ── Six dots ─────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(6, (i) {
                final filled = i < _pin.length;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? primary : Colors.transparent,
                    border: Border.all(
                      color: filled ? primary : subtextColor,
                      width: 2,
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 10),

            // ── Error message ────────────────────────────────────────────
            SizedBox(
              height: 18,
              child: _errorMessage != null
                  ? Text(
                      _errorMessage!,
                      style: TextStyle(
                        color: t.colorScheme.error,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    )
                  : null,
            ),
            const SizedBox(height: 16),

            // ── Keypad ───────────────────────────────────────────────────
            _buildKeyRow(['1', '2', '3'], cardCol, textColor),
            const SizedBox(height: 8),
            _buildKeyRow(['4', '5', '6'], cardCol, textColor),
            const SizedBox(height: 8),
            _buildKeyRow(['7', '8', '9'], cardCol, textColor),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 60, height: 52), // spacer
                const SizedBox(width: 8),
                _keyBtn('0', cardCol, textColor),
                const SizedBox(width: 8),
                _iconBtn(Icons.backspace_outlined, cardCol, textColor),
              ],
            ),

            const SizedBox(height: 20),

            // ── Cancel ───────────────────────────────────────────────────
            if (_checking)
              const SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
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

  Widget _buildKeyRow(List<String> digits, Color card, Color text) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: digits.map((d) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: _keyBtn(d, card, text),
        );
      }).toList(),
    );
  }

  Widget _keyBtn(String digit, Color card, Color text) {
    return Material(
      color: card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _onDigit(digit),
        child: SizedBox(
          width: 60,
          height: 52,
          child: Center(
            child: Text(
              digit,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: text,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, Color card, Color text) {
    return Material(
      color: card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _onBackspace,
        child: SizedBox(
          width: 60,
          height: 52,
          child: Center(child: Icon(icon, color: text, size: 22)),
        ),
      ),
    );
  }
}
