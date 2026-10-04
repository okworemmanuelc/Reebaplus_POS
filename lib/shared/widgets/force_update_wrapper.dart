import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

class ForceUpdateWrapper extends StatefulWidget {
  final Widget child;

  const ForceUpdateWrapper({super.key, required this.child});

  @override
  State<ForceUpdateWrapper> createState() => _ForceUpdateWrapperState();
}

class _ForceUpdateWrapperState extends State<ForceUpdateWrapper> {
  bool _checking = true;
  bool _needsUpdate = false;

  @override
  void initState() {
    super.initState();
    _checkAppVersion();
  }

  Future<void> _checkAppVersion() async {
    // In a real production app, this would hit Supabase or RemoteConfig.
    // For now, we simulate a fast, successful check returning "Update not required".
    await Future.delayed(const Duration(milliseconds: 500));

    if (mounted) {
      setState(() {
        _checking = false;
        _needsUpdate = false; // set to true to test blocking functionality
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator(color: Colors.white)),
        ),
      );
    }

    if (_needsUpdate) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(
                child: Image.asset(
                  'assets/images/auth_bg.png',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(color: Colors.black),
                ),
              ),
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.7)),
              ),
              SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          AppIcons.update,
                          size: 80,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Update Required',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'You are using an outdated version of Reebaplus POS. Please update the app to continue securely.',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withValues(alpha: 0.7),
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 40),
                        ElevatedButton(
                          onPressed: () {
                            // Target external store links (App Store / Play Store) natively.
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            minimumSize: const Size(double.infinity, 54),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text(
                            'Update Now',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return widget.child;
  }
}
