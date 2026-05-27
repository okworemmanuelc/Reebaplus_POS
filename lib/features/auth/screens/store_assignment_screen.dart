import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';

class StoreAssignmentScreen extends ConsumerStatefulWidget {
  final UserData user;
  const StoreAssignmentScreen({super.key, required this.user});

  @override
  ConsumerState<StoreAssignmentScreen> createState() =>
      _StoreAssignmentScreenState();
}

class _StoreAssignmentScreenState
    extends ConsumerState<StoreAssignmentScreen> {
  late Timer _timer;
  Duration _timeLeft = Duration.zero;
  late DateTime _expiry;
  late Timer _assignmentCheckTimer;

  // Captured at initState — Timer.periodic fires `_checkAssignment` across
  // dispose windows; touching `ref` from a fired callback would race the
  // riverpod element-unmount invalidation. See plan §"Bug fix" Pattern 1.
  late final AppDatabase _db;
  late final AuthService _auth;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseProvider);
    _auth = ref.read(authProvider);
    _expiry = widget.user.createdAt.add(
      const Duration(hours: 48),
    );
    _calculateTimeLeft();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _calculateTimeLeft(),
    );

    // Poll for assignment every 5 seconds
    _assignmentCheckTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkAssignment(),
    );
  }

  Future<void> _checkAssignment() async {
    final updatedUser = await (_db.select(
      _db.users,
    )..where((u) => u.id.equals(widget.user.id))).getSingleOrNull();

    if (updatedUser != null && updatedUser.storeId != null) {
      // Assignment detected!
      _auth.setCurrentUser(updatedUser, freshSignIn: true);
    }
  }

  void _calculateTimeLeft() {
    final now = DateTime.now();
    final diff = _expiry.difference(now);

    if (mounted) {
      setState(() {
        _timeLeft = diff.isNegative ? Duration.zero : diff;
      });
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    _assignmentCheckTimer.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final subtext = textColor.withValues(alpha: 0.8);

    return AuthBackground(
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      FontAwesomeIcons.store,
                      size: 40,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  decoration: AppDecorations.glassCard(context, radius: 16),
                  child: Column(
                    children: [
                      Text(
                        'Waiting for Assignment',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Hello ${widget.user.name.split(' ')[0]}, your account is active but hasn\'t been assigned a store yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          color: subtext,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 48),

                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: AppDecorations.glassCard(context, radius: 24),
                  child: Column(
                    children: [
                      Text(
                        'TIME UNTIL ESCALATION',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                          color: textColor.withValues(alpha: 0.9),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _formatDuration(_timeLeft),
                        style: TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.w300,
                          fontFamily: 'monospace',
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _timeLeft.inSeconds / (48 * 3600),
                        backgroundColor: textColor.withValues(alpha: 0.1),
                        color: theme.colorScheme.primary,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 48),

                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: AppDecorations.glassCard(context, radius: 12),
                  child: Text(
                    'The CEO has been notified. This timer secures your onboarding window.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: subtext),
                  ),
                ),
                const SizedBox(height: 24),

                AppButton(
                  text: 'Log Out',
                  icon: FontAwesomeIcons.rightFromBracket,
                  variant: AppButtonVariant.ghost,
                  isFullWidth: false,
                  onPressed: () => _auth.fullLogout(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
