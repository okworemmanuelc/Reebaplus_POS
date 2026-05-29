import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

/// Branded auth typography + form primitives, extracted from CEO Sign Up so
/// every auth screen shares one look. Pair with [BrandedAuthBackground].

const TextStyle authTitleStyle = TextStyle(
  fontSize: 26,
  fontWeight: FontWeight.w800,
  color: adTextPrimary,
);

final TextStyle authSubtitleStyle = TextStyle(
  fontSize: 15,
  height: 1.4,
  color: adTextPrimary.withValues(alpha: 0.65),
);

/// Scrollable title/subtitle shell for form-style auth steps. Keeps content
/// clear of the keyboard via the bottom view inset.
class AuthFormShell extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> children;

  const AuthFormShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        28,
        12,
        28,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: authTitleStyle),
          const SizedBox(height: 8),
          Text(subtitle, style: authSubtitleStyle),
          const SizedBox(height: 28),
          ...children,
        ],
      ),
    );
  }
}

/// Glass-card wrapper for a single input field.
class AuthInputCard extends StatelessWidget {
  final Widget child;
  const AuthInputCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppDecorations.glassCard(context),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

/// Fixed-height inline error slot — reserves space so the layout doesn't jump
/// when an error appears/clears. Renders nothing when [message] is null.
class AuthErrorText extends StatelessWidget {
  final String? message;
  const AuthErrorText(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: message == null
          ? null
          : Text(
              message!,
              style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 13),
            ),
    );
  }
}
