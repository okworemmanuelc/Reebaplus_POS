import 'dart:async';
import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/shared/widgets/smooth_route.dart';

class SuccessDashboardEntryScreen extends StatefulWidget {
  const SuccessDashboardEntryScreen({super.key});

  @override
  State<SuccessDashboardEntryScreen> createState() =>
      _SuccessDashboardEntryScreenState();
}

class _SuccessDashboardEntryScreenState
    extends State<SuccessDashboardEntryScreen> {
  Timer? _forwardTimer;

  @override
  void initState() {
    super.initState();
    _startAutoForward();
  }

  void _startAutoForward() {
    _forwardTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;

      // Onboarding is a CEO flow, so MainLayout lands on Home with the Get
      // Started checklist; its "Add your first product" CTA is the route into
      // the catalogue (ADR 0006) — no auto-push of the Add Product form.
      Navigator.of(context).pushAndRemoveUntil(
        SmoothRoute(page: const MainLayout()),
        (route) => false,
      );
    });
  }

  @override
  void dispose() {
    _forwardTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;

    return Scaffold(
      body: BrandedAuthBackground(
        child: SafeArea(
          child: AuthCenteredScroll(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Success Icon
              Container(
                padding: EdgeInsets.all(context.getRSize(24)),
                decoration: BoxDecoration(
                  color: f.greenTint,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  AppIcons.checkCircle,
                  color: f.green,
                  size: context.getRSize(80),
                ),
              ),
              SizedBox(height: context.getRSize(32)),

              // Success Text
              Text(
                'Your business is ready!',
                textAlign: TextAlign.center,
                style: context
                    .extraBoldStyle(30)
                    .copyWith(color: authTextPrimary(context)),
              ),
              SizedBox(height: context.getRSize(12)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(40)),
                child: Text(
                  'Preparing your dashboard...',
                  textAlign: TextAlign.center,
                  style: authSubtitleStyle(context),
                ),
              ),
              SizedBox(height: context.getRSize(48)),

              SizedBox(
                width: context.getRSize(24),
                height: context.getRSize(24),
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
