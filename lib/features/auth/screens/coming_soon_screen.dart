import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

/// Minimal dark-themed placeholder for routes not yet built (master plan §4
/// uses placeholder routes for Terms/Privacy; the real invite-code entry is
/// step 8). Reused for Join with invite code, Terms of Service, Privacy Policy.
class ComingSoonScreen extends StatelessWidget {
  final String title;
  final String message;

  const ComingSoonScreen({
    super.key,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: adBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: adTextPrimary),
        title: Text(
          title,
          style: const TextStyle(
            color: adTextPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.hourglass_empty_rounded,
                size: 56,
                color: amberPrimary.withValues(alpha: 0.8),
              ),
              const SizedBox(height: 20),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: adTextPrimary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
