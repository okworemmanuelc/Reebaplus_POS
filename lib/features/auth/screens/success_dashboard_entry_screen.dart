import 'package:flutter/material.dart';

import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/shared/widgets/smooth_route.dart';

class SuccessDashboardEntryScreen extends StatefulWidget {
  const SuccessDashboardEntryScreen({super.key});

  @override
  State<SuccessDashboardEntryScreen> createState() =>
      _SuccessDashboardEntryScreenState();
}

class _SuccessDashboardEntryScreenState
    extends State<SuccessDashboardEntryScreen> {
  @override
  void initState() {
    super.initState();
    _startAutoForward();
  }

  void _startAutoForward() {
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;

      // Onboarding lands on POS with the empty-state "Add your first product"
      // CTA (ADR 0006) — no auto-push of the Add Product form.
      Navigator.of(context).pushAndRemoveUntil(
        SmoothRoute(page: const MainLayout()),
        (route) => false,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return AuthBackground(
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Success Icon
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: Colors.greenAccent,
                  size: 80,
                ),
              ),
              const SizedBox(height: 32),

              // Success Text
              Text(
                'Your business is ready!',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Preparing your Point of Sale...',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: textColor.withValues(alpha: 0.7),
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 48),

              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
