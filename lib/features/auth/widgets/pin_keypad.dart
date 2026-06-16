import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';

/// Six amber PIN dots. [filled] is how many are entered (0–6).
///
/// Shared by CEO Sign Up, Create PIN and Login so the branded look is
/// defined once. Callers that drive the PIN through a ValueNotifier (Login's
/// 120fps path) wrap this in a `ValueListenableBuilder`.
class PinDots extends StatelessWidget {
  final int filled;
  const PinDots({super.key, required this.filled});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (i) {
        final isFilled = i < filled;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFilled
                ? Theme.of(context).colorScheme.primary
                : authTextPrimary(context).withValues(alpha: 0.05),
            border: Border.all(
              color: isFilled
                  ? Theme.of(context).colorScheme.primary
                  : authTextPrimary(context).withValues(alpha: 0.2),
              width: 2,
            ),
          ),
        );
      }),
    );
  }
}

/// A single 64×64 glass key. Public so callers can build a matching key for
/// the keypad's bottom-left slot (e.g. Login's biometric button).
class PinKey extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;

  const PinKey({super.key, this.label, this.icon, required this.onTap})
    : assert(label != null || icon != null, 'PinKey needs a label or an icon');

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onHighlightChanged: (h) {
            if (h) HapticFeedback.lightImpact();
          },
          onTap: onTap,
          child: SizedBox(
            width: 64,
            height: 64,
            child: Center(
              child: icon != null
                  ? Icon(icon, color: authTextPrimary(context), size: 22)
                  : Text(
                      label!,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: authTextPrimary(context),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Branded numeric keypad (1–9, 0, backspace) built from [PinKey].
///
/// [leadingKey] fills the bottom-left slot beside 0 — null for CEO Sign Up /
/// Create PIN, Login passes its biometric [PinKey] there.
class PinKeypad extends StatelessWidget {
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final Widget? leadingKey;

  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.leadingKey,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Column(
        children: [
          _row(const ['1', '2', '3']),
          const SizedBox(height: 8),
          _row(const ['4', '5', '6']),
          const SizedBox(height: 8),
          _row(const ['7', '8', '9']),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              leadingKey ?? const SizedBox(width: 64, height: 64),
              const SizedBox(width: 12),
              PinKey(label: '0', onTap: () => onDigit('0')),
              const SizedBox(width: 12),
              PinKey(icon: Icons.backspace_outlined, onTap: onBackspace),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: digits
          .map(
            (d) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: PinKey(label: d, onTap: () => onDigit(d)),
            ),
          )
          .toList(),
    );
  }
}
