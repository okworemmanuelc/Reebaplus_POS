import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/shopper_session.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Shopper sign-in (#426): email, then the one-time code. No PIN; the session
/// persists. Asked only at Place order (or from My Orders). Pops `true` once
/// signed in. A login with no business lands back here on the Shopper side —
/// this never runs the business sign-in routing ("No account found").
class ShopperSignInScreen extends ConsumerStatefulWidget {
  const ShopperSignInScreen({super.key});

  @override
  ConsumerState<ShopperSignInScreen> createState() =>
      _ShopperSignInScreenState();
}

class _ShopperSignInScreenState extends ConsumerState<ShopperSignInScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  String? _sentTo;
  String? _error;
  bool _busy = false;

  static final _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (!_emailShape.hasMatch(email)) {
      setState(() => _error = 'Type a valid email address');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await ref
        .read(shopperSessionProvider.notifier)
        .sendCode(email);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) {
        _sentTo = email;
        _code.clear();
      }
    });
  }

  Future<void> _verify() async {
    final email = _sentTo;
    final code = _code.text.trim();
    if (email == null) return;
    if (code.length < 6) {
      setState(() => _error = 'Type the code from your email');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await ref
        .read(shopperSessionProvider.notifier)
        .verifyCode(email, code);
    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final sentTo = _sentTo;
    return ShopperPage(
      icon: AppIcons.email,
      title: 'Sign in to order',
      body: SingleChildScrollView(
        key: const Key('shopper-sign-in-scroll'),
        padding: EdgeInsets.fromLTRB(
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(24) + context.deviceBottomPadding,
        ),
        child: ShopperSection(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                sentTo == null
                    ? "Type your email. We'll send you a code — no password "
                          'or PIN needed. Your cart stays as it is.'
                    : 'We sent a code to $sentTo. Type it below.',
                style: context.regularStyle(14).copyWith(color: muted),
              ),
              SizedBox(height: context.getRSize(12)),
              if (sentTo == null)
                AppInput(
                  key: const Key('shopper-email'),
                  controller: _email,
                  labelText: 'Email',
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.send,
                  autocorrect: false,
                  onFieldSubmitted: (_) => _busy ? null : _send(),
                )
              else
                AppInput(
                  key: const Key('shopper-code'),
                  controller: _code,
                  labelText: 'Code',
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(8),
                  ],
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _busy ? null : _verify(),
                ),
              if (_error != null) ...[
                SizedBox(height: context.getRSize(8)),
                Text(
                  _error!,
                  key: const Key('shopper-sign-in-error'),
                  style: context
                      .semiBoldStyle(13)
                      .copyWith(color: t.colorScheme.error),
                ),
              ],
              SizedBox(height: context.getRSize(16)),
              AppButton(
                key: const Key('shopper-sign-in-submit'),
                text: sentTo == null ? 'Send code' : 'Sign in',
                isLoading: _busy,
                onPressed: _busy ? null : (sentTo == null ? _send : _verify),
              ),
              if (sentTo != null) ...[
                SizedBox(height: context.getRSize(8)),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    AppButton(
                      text: 'Send a new code',
                      variant: AppButtonVariant.ghost,
                      isFullWidth: false,
                      onPressed: _busy ? null : _send,
                    ),
                    AppButton(
                      text: 'Use another email',
                      variant: AppButtonVariant.ghost,
                      isFullWidth: false,
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _sentTo = null;
                              _error = null;
                            }),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
