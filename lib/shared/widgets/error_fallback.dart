import 'package:flutter/material.dart';

/// Friendly, calm fallback shown in place of a crash (master plan §33.2).
///
/// Deliberately self-contained: it provides its own [Directionality] and
/// [Material] ancestor and uses fixed (non-`Theme.of`) colours so it is safe to
/// render even as the global [ErrorWidget.builder] — i.e. when a widget's build
/// threw and there may be no Theme/Directionality in scope. It must never throw.
///
/// Two uses:
///  - Global build-error replacement (no [onRetry]) — replaces Flutter's red
///    error box with a small "Something went wrong here" card.
///  - Per-screen error state (with [onRetry]) for the role-prioritised error
///    boundaries (§33.4).
class ErrorFallback extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  /// Compact = a small inline card (a single broken widget). Non-compact fills
  /// the available space (a whole screen body that failed to load).
  final bool compact;

  const ErrorFallback({
    super.key,
    this.message = 'Something went wrong here.',
    this.onRetry,
    this.compact = false,
  });

  static const Color _bg = Color(0xFFFDF6EC); // warm, calm — never red
  static const Color _icon = Color(0xFFB26A00);
  static const Color _text = Color(0xFF5A4632);

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline_rounded, size: 40, color: _icon),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, height: 1.4, color: _text),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 16),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: _icon),
            child: const Text('Try again'),
          ),
        ],
      ],
    );

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: _bg,
        child: Padding(
          padding: EdgeInsets.all(compact ? 16 : 24),
          child: Center(child: content),
        ),
      ),
    );
  }
}
