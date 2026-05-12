/// Invite-code display widgets.
///
/// Two public widgets share the same internal layout primitives:
///   • [InviteCodeBlock] — just the glass-card code container plus Copy
///     and (optional) share buttons. Used standalone by the new
///     pending-invite sheet so it can append its own admin actions below.
///   • [CodeShareCard] — drop-in modal body for "Code ready to share" /
///     "New code generated" flows. Adds a drag handle, title, optional
///     subtitle, and a Done button around [InviteCodeBlock].
///
/// Both widgets are pure — no provider access, no internal state beyond
/// what the constructor receives. The share-message template is
/// constructed inside [InviteCodeBlock] so every share channel surfaces
/// the exact same wording. TTL defaults to 7 days; callers can pass the
/// remaining-days value for a pending invite, or the full TTL for a
/// freshly-issued one.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

class InviteCodeBlock extends StatelessWidget {
  final String humanCode;
  final String businessName;
  final String? recipientName;
  final String? email;
  final int ttlDays;

  /// URL launcher injected by the parent. When null, the share buttons
  /// (WhatsApp / SMS / Email) are hidden — Copy still works via Flutter's
  /// built-in `Clipboard.setData`. Task #20 will pass `launchUrl` from
  /// `package:url_launcher`.
  final Future<bool> Function(Uri uri)? onLaunch;

  const InviteCodeBlock({
    super.key,
    required this.humanCode,
    required this.businessName,
    this.recipientName,
    this.email,
    this.ttlDays = 7,
    this.onLaunch,
  });

  String get _greetingName =>
      (recipientName?.trim().isNotEmpty ?? false) ? recipientName!.trim() : 'there';

  String get _shareMessage =>
      "Hi $_greetingName, you've been invited to join $businessName on Reeba POS. "
      "Your code is: $humanCode. Open the app, choose 'Join a business,' "
      "and enter the code. The code expires in $ttlDays day${ttlDays == 1 ? '' : 's'}.";

  String get _emailSubject =>
      "You've been invited to $businessName on Reeba POS";

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final subtleColor = textColor.withValues(alpha: 0.6);
    final canShare = onLaunch != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: AppDecorations.glassCard(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.qr_code_2_rounded, size: 18, color: subtleColor),
                  const SizedBox(width: 8),
                  Text(
                    '8-character code',
                    style: TextStyle(fontSize: 12, color: subtleColor),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                humanCode,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                  color: textColor,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                ttlDays <= 0
                    ? 'Expired'
                    : 'Expires in $ttlDays day${ttlDays == 1 ? '' : 's'}',
                style: TextStyle(fontSize: 12, color: subtleColor),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppButton(
          text: 'Copy code',
          variant: AppButtonVariant.primary,
          onPressed: () => _copyCode(context),
        ),
        if (canShare) ...[
          const SizedBox(height: 8),
          AppButton(
            text: 'Share on WhatsApp',
            variant: AppButtonVariant.secondary,
            onPressed: _launchWhatsApp,
          ),
          const SizedBox(height: 8),
          AppButton(
            text: 'Send via SMS',
            variant: AppButtonVariant.secondary,
            onPressed: _launchSms,
          ),
          if ((email?.trim().isNotEmpty ?? false)) ...[
            const SizedBox(height: 8),
            AppButton(
              text: 'Send via Email',
              variant: AppButtonVariant.secondary,
              onPressed: _launchEmail,
            ),
          ],
        ],
      ],
    );
  }

  Future<void> _copyCode(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: humanCode));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code copied')),
    );
  }

  Future<void> _launchWhatsApp() async {
    final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(_shareMessage)}');
    await onLaunch?.call(uri);
  }

  Future<void> _launchSms() async {
    final uri = Uri.parse('sms:?body=${Uri.encodeComponent(_shareMessage)}');
    await onLaunch?.call(uri);
  }

  Future<void> _launchEmail() async {
    final to = email?.trim() ?? '';
    final uri = Uri.parse(
      'mailto:$to'
      '?subject=${Uri.encodeComponent(_emailSubject)}'
      '&body=${Uri.encodeComponent(_shareMessage)}',
    );
    await onLaunch?.call(uri);
  }
}

class CodeShareCard extends StatelessWidget {
  final String humanCode;
  final String businessName;
  final String? recipientName;
  final String? email;

  /// Title displayed above the code. Defaults to "Code ready to share".
  final String? title;

  /// Optional subtitle below the title.
  final String? subtitle;

  /// Invite TTL in days. Defaults to 7.
  final int ttlDays;

  /// See [InviteCodeBlock.onLaunch].
  final Future<bool> Function(Uri uri)? onLaunch;

  /// Callback fired when the user taps "Done". Typically pops the hosting
  /// dialog / modal.
  final VoidCallback? onDone;

  const CodeShareCard({
    super.key,
    required this.humanCode,
    required this.businessName,
    this.recipientName,
    this.email,
    this.title,
    this.subtitle,
    this.ttlDays = 7,
    this.onLaunch,
    this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final subtleColor = textColor.withValues(alpha: 0.6);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: textColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Text(
          title ?? 'Code ready to share',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: subtleColor),
          ),
        ],
        const SizedBox(height: 20),
        InviteCodeBlock(
          humanCode: humanCode,
          businessName: businessName,
          recipientName: recipientName,
          email: email,
          ttlDays: ttlDays,
          onLaunch: onLaunch,
        ),
        const SizedBox(height: 8),
        AppButton(
          text: 'Done',
          variant: AppButtonVariant.ghost,
          onPressed: onDone ?? () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}
