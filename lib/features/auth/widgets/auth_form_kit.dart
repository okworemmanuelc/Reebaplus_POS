import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';

/// Branded auth typography + form primitives, extracted from CEO Sign Up so
/// every auth screen shares one look. Pair with [BrandedAuthBackground].
///
/// Title/subtitle styles are theme-aware (light/dark + active accent) — pass
/// the build context so the colour resolves against the current theme.

TextStyle authTitleStyle(BuildContext context) => TextStyle(
  fontSize: 26,
  fontWeight: FontWeight.w800,
  color: authTextPrimary(context),
);

TextStyle authSubtitleStyle(BuildContext context) => TextStyle(
  fontSize: 15,
  height: 1.4,
  color: authTextMuted(context),
);

/// Vertically-centred, scroll-when-tall content area for auth screens that
/// don't use [AuthFormShell] (custom step/content screens). Centres [children]
/// in the viewport and scrolls if the content (or keyboard) needs more room.
/// Children stretch to full width (use a leading [Stack]/[Align] for any
/// pinned top-left back button — see the login screen pattern).
class AuthCenteredScroll extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets? padding;
  final CrossAxisAlignment crossAxisAlignment;

  const AuthCenteredScroll({
    super.key,
    required this.children,
    this.padding,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  @override
  Widget build(BuildContext context) {
    final pad = padding ??
        EdgeInsets.fromLTRB(
          28,
          12,
          28,
          MediaQuery.of(context).viewInsets.bottom + 24,
        );
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: pad,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: crossAxisAlignment,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

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
    // Vertically centred when the content is shorter than the viewport, and
    // scrollable when it's taller (or the keyboard is up). minHeight ties the
    // content box to the available height so MainAxisAlignment.center works.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              28,
              12,
              28,
              MediaQuery.of(context).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: authTitleStyle(context)),
                const SizedBox(height: 8),
                Text(subtitle, style: authSubtitleStyle(context)),
                const SizedBox(height: 28),
                ...children,
              ],
            ),
          ),
        ),
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
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
    );
  }
}
