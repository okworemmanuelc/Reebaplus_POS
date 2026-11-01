import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:reebaplus_pos/core/services/min_build_source.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Package id on Google Play (android/app/build.gradle applicationId).
const String kPlayStorePackageId = 'com.reebaplus.pos';

/// Minimum gap between two server checks (launch + resume are debounced).
const Duration kMinBuildCheckGap = Duration(minutes: 1);

/// Must-update switch (#626). Never blocks app open: the child renders
/// immediately and the full-screen update page only replaces it when the
/// server's `min_android_build` is POSITIVELY above this build. Offline,
/// fetch error, non-Android, or build >= minimum all leave the app open.
/// There is deliberately no local cache: with no answer from the server
/// nothing is blocked.
class ForceUpdateWrapper extends StatefulWidget {
  final Widget child;

  /// Test seams.
  final MinBuildFetcher? fetchMinBuild;
  final Future<int?> Function()? currentBuild;
  final bool? isAndroid;
  final Future<void> Function()? openStore;

  const ForceUpdateWrapper({
    super.key,
    required this.child,
    this.fetchMinBuild,
    this.currentBuild,
    this.isAndroid,
    this.openStore,
  });

  @override
  State<ForceUpdateWrapper> createState() => _ForceUpdateWrapperState();
}

class _ForceUpdateWrapperState extends State<ForceUpdateWrapper>
    with WidgetsBindingObserver {
  bool _needsUpdate = false;
  bool _inFlight = false;
  DateTime? _lastCheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_checkAppVersion());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_checkAppVersion());
  }

  Future<int?> _ownBuild() async {
    try {
      return int.tryParse((await PackageInfo.fromPlatform()).buildNumber);
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkAppVersion() async {
    final android =
        widget.isAndroid ?? defaultTargetPlatform == TargetPlatform.android;
    if (!android || _inFlight) return;
    final last = _lastCheck;
    if (last != null && DateTime.now().difference(last) < kMinBuildCheckGap) {
      return;
    }
    _inFlight = true;
    _lastCheck = DateTime.now();
    try {
      final min = await (widget.fetchMinBuild ?? fetchMinAndroidBuild)();
      final own = await (widget.currentBuild ?? _ownBuild)();
      if (min == null || own == null) return; // no answer = no block
      final needs = own < min;
      if (mounted && needs != _needsUpdate) {
        setState(() => _needsUpdate = needs);
      }
    } catch (_) {
      // never block on an error
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _openStore() async {
    final custom = widget.openStore;
    if (custom != null) return custom();
    final market = Uri.parse('market://details?id=$kPlayStorePackageId');
    final web = Uri.parse(
      'https://play.google.com/store/apps/details?id=$kPlayStorePackageId',
    );
    try {
      if (await launchUrl(market, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    await launchUrl(web, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
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
                          onPressed: () => unawaited(_openStore()),
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
