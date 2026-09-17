import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show DiagnosticsDebugCreator;
import 'package:flutter/widgets.dart';

import 'package:reebaplus_pos/shared/widgets/tab_navigator.dart';

/// One layout overflow, tagged with the screen it happened on.
@immutable
class OverflowReport {
  /// The framework's one-line summary, e.g.
  /// `A RenderFlex overflowed by 19 pixels on the bottom.`
  final String summary;

  /// The innermost enclosing screen, sheet or dialog widget — the surface the
  /// user was looking at. `null` when the creator chain is unavailable.
  final String? screen;

  /// The root screen of the bottom-nav tab the overflow sits in, or `null` when
  /// it is outside MainLayout (auth flow, a root-navigator dialog).
  final String? tab;

  /// True when the overflowing widget sits under an offstage or ticker-muted
  /// subtree — a pre-warmed tab the user is not looking at.
  final bool offstage;

  /// The widget whose render object overflowed, e.g. `Column`.
  final String? widget;

  const OverflowReport({
    required this.summary,
    this.screen,
    this.tab,
    this.offstage = false,
    this.widget,
  });

  /// The route tag: screen, then tab when it adds information.
  String get route {
    final label = screen ?? '(unknown screen)';
    final parts = <String>[
      if (tab != null && tab != screen) 'tab: $tab',
      if (offstage) 'offstage',
    ];
    return parts.isEmpty ? label : '$label (${parts.join(', ')})';
  }

  @override
  String toString() =>
      '${OverflowRouteReporter.tag} route=$route widget=${widget ?? '?'} :: $summary';
}

/// Debug-only hook that tags every layout overflow report with the screen it
/// fired on (PRD #239 / issue #241).
///
/// A starved layout announces itself only as `A RenderFlex overflowed by N
/// pixels` plus a creator chain dozens of frames deep, which does not say which
/// screen to fix. This hook resolves the owner from the report itself: an
/// overflow report carries the overflowing render object's `DebugCreator`, and
/// walking that element's ancestors yields the enclosing `*Screen` / `*Sheet` /
/// `*Dialog` widget and the bottom-nav tab. Tagging the owner — rather than
/// whichever route is on top — also attributes overflows in offstage,
/// pre-warmed tabs correctly.
///
/// Inert outside debug builds: [install] returns before touching
/// [FlutterError.onError], and `kDebugMode` lets the tree-shaker drop it.
class OverflowRouteReporter {
  OverflowRouteReporter._();

  /// Prefix every tagged line carries, so `adb logcat | grep` can find them.
  static const String tag = '[overflow]';

  /// Wraps [FlutterError.onError] so overflow reports also print a tagged line.
  /// Every report still reaches the previous handler unchanged. Call after
  /// `CrashReporter.install()`.
  ///
  /// [enabled] exists for tests; production callers leave it at `kDebugMode`.
  static void install({
    bool enabled = kDebugMode,
    void Function(OverflowReport report)? onReport,
  }) {
    if (!enabled) return;
    final FlutterExceptionHandler? prior = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      try {
        final report = describe(details);
        if (report != null) {
          (onReport ?? _print)(report);
        }
      } catch (_) {
        // A diagnostic must never break the error path it observes.
      }
      if (prior != null) {
        prior(details);
      } else {
        FlutterError.presentError(details);
      }
    };
  }

  static void _print(OverflowReport report) => debugPrint('$report');

  /// Whether [details] is a layout overflow report.
  static bool isOverflow(FlutterErrorDetails details) {
    final exception = details.exception;
    return exception is FlutterError &&
        exception.message.contains(' overflowed by ');
  }

  /// Tags [details] with its owning screen, or returns `null` when it is not a
  /// layout overflow.
  static OverflowReport? describe(FlutterErrorDetails details) {
    if (!isOverflow(details)) return null;
    final summary = (details.exception as FlutterError).message.split('\n').first;
    final element = _creatorElement(details);
    if (element == null) return OverflowReport(summary: summary);

    String? screen;
    String? tab;
    var offstage = false;
    bool visit(Element ancestor) {
      final widget = ancestor.widget;
      final name = widget.runtimeType.toString();
      if (screen == null && _isSurfaceName(name)) screen = name;
      if (widget is Offstage && widget.offstage) offstage = true;
      if (widget is TickerMode && !widget.enabled) offstage = true;
      if (widget is TabNavigator) {
        tab = widget.rootScreen.runtimeType.toString();
      }
      return true;
    }

    visit(element);
    element.visitAncestorElements(visit);
    return OverflowReport(
      summary: summary,
      screen: screen ?? tab,
      tab: tab,
      offstage: offstage,
      widget: element.widget.runtimeType.toString(),
    );
  }

  static Element? _creatorElement(FlutterErrorDetails details) {
    final nodes = details.informationCollector?.call() ?? const <DiagnosticsNode>[];
    for (final node in nodes) {
      if (node is DiagnosticsDebugCreator) {
        final creator = node.value;
        if (creator is DebugCreator) return creator.element;
      }
    }
    return null;
  }

  static bool _isSurfaceName(String name) {
    // Generic wrappers such as `_ModalScope<void>` are not screens.
    if (name.startsWith('_') || name.contains('<')) return false;
    return name.endsWith('Screen') ||
        name.endsWith('Sheet') ||
        name.endsWith('Dialog') ||
        name.endsWith('Page');
  }
}
