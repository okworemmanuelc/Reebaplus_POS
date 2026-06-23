import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/sync/widgets/initial_load_animation.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Loading screen shown only while the local DB has no `businesses` row
/// (fresh device sign-in). Runs `syncMinimumLogin` to pull the 4 tables
/// MainLayout needs to render (profiles, businesses, users, stores).
/// Expected wall-clock: ~1–6 s depending on link speed. The whole-tenant
/// pull continues in the background from `setCurrentUser` after MainLayout
/// mounts. Shows error + retry UI on failure.
class FirstSyncScreen extends ConsumerStatefulWidget {
  final String businessId;

  const FirstSyncScreen({super.key, required this.businessId});

  @override
  ConsumerState<FirstSyncScreen> createState() => _FirstSyncScreenState();
}

class _FirstSyncScreenState extends ConsumerState<FirstSyncScreen> {
  bool _syncing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _startInitialSync();
  }

  Future<void> _startInitialSync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _errorMessage = null;
    });

    try {
      final syncService = ref.read(supabaseSyncServiceProvider);
      await syncService.syncMinimumLogin(widget.businessId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage =
              e is PartialPullException ||
                  e.toString().contains('SocketException') ||
                  e.toString().contains('Failed host lookup') ||
                  e.toString().contains('TimeoutException')
              ? 'No internet connection detected. Please verify your connection and try again.'
              : 'Sync failed: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage == null) {
      return const InitialLoadAnimation();
    }

    return _ErrorPanel(
      errorMessage: _errorMessage!,
      onRetry: _startInitialSync,
    );
  }
}

/// Shown when the minimum pull fails — offline or server error.
class _ErrorPanel extends StatelessWidget {
  final String errorMessage;
  final VoidCallback onRetry;

  const _ErrorPanel({required this.errorMessage, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: AppDecorations.glassyBackground(context),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(24),
              vertical: context.getRSize(32),
            ),
            child: Column(
              children: [
                const Spacer(),
                FaIcon(
                  FontAwesomeIcons.triangleExclamation,
                  size: context.getRSize(56),
                  color: cs.error,
                ),
                SizedBox(height: context.getRSize(24)),
                Text(
                  'Sync Paused',
                  style: t.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                    letterSpacing: -0.5,
                  ),
                ),
                SizedBox(height: context.getRSize(12)),
                Text(
                  'Syncing Your Store',
                  style: t.textTheme.titleMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: EdgeInsets.all(context.getRSize(16)),
                  decoration: AppDecorations.glassCard(context, radius: 20),
                  child: Column(
                    children: [
                      Text(
                        errorMessage,
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodySmall?.copyWith(
                          color: cs.error,
                        ),
                      ),
                      SizedBox(height: context.getRSize(16)),
                      AppButton(
                        text: 'Retry Synchronization',
                        variant: AppButtonVariant.primary,
                        size: AppButtonSize.small,
                        icon: FontAwesomeIcons.arrowsRotate.data,
                        onPressed: onRetry,
                      ),
                    ],
                  ),
                ),
                SizedBox(height: context.getRSize(16)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
