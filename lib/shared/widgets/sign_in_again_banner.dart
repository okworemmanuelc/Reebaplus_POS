import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/auth_refresh_observer.dart';
import 'package:reebaplus_pos/core/services/cloud_login_state.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/features/auth/screens/session_expired_screen.dart';

/// What the banner says. Plain words: the shop's sales are safe, they are just
/// not reaching the cloud yet.
const String kSignInAgainBannerText =
    'Your sales are saved on this phone but are not backing up online.';

/// Shown at the top of MainLayout while the signed-in user has no cloud login
/// (#798). Never blocks: the shop keeps selling and taps "Sign in again" when
/// it suits them. Renders nothing the rest of the time.
///
/// [lost] defaults to the app-wide [cloudLoginLost]; tests pass their own.
class SignInAgainBanner extends ConsumerStatefulWidget {
  const SignInAgainBanner({super.key, this.lost});

  final ValueListenable<bool>? lost;

  @override
  ConsumerState<SignInAgainBanner> createState() => _SignInAgainBannerState();
}

class _SignInAgainBannerState extends ConsumerState<SignInAgainBanner> {
  /// One cloud record per loss, not per rebuild.
  bool _recorded = false;

  ValueListenable<bool> get _lost => widget.lost ?? cloudLoginLost;

  void _recordOnce(String businessId, String userId) {
    if (_recorded) return;
    _recorded = true;
    // Same context name the old blocking screen used, so the history in
    // `error_logs` stays in one series. It uploads after the next sign-in.
    final refusal = AuthRefreshObserverClient.reasonAt(DateTime.now());
    ref.read(authProvider).getAuthMethod().then((method) => method,
        onError: (Object _) => null).then((method) {
      CrashReporter.record(
        'cloud login lost, banner shown '
        '(authMethod=${method ?? 'unknown'}, refusal: $refusal)',
        StackTrace.current,
        context: 'auth.session_expired_gate',
        businessId: businessId,
        userId: userId,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).value;
    return ValueListenableBuilder<bool>(
      valueListenable: _lost,
      builder: (context, lost, _) {
        if (!lost) {
          _recorded = false;
          return const SizedBox.shrink();
        }
        if (user == null) return const SizedBox.shrink();
        _recordOnce(user.businessId, user.id);
        final t = Theme.of(context);
        return Material(
          color: t.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    kSignInAgainBannerText,
                    style: t.textTheme.bodySmall?.copyWith(
                      color: t.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('sign-in-again'),
                  onPressed: () {
                    final navigator = Navigator.of(context);
                    navigator.push(
                      MaterialPageRoute<void>(
                        builder: (_) => SessionExpiredScreen(
                          user: user,
                          onNotNow: navigator.pop,
                        ),
                      ),
                    );
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: t.colorScheme.onErrorContainer,
                  ),
                  child: const Text('Sign in again'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
