import 'package:flutter/material.dart';

/// Semantic color tokens exposed as a [ThemeExtension].
///
/// Widgets access these via:
/// ```dart
/// Theme.of(context).extension<AppSemanticColors>()!.success
/// ```
///
/// Each palette variant installs its own [AppSemanticColors] instance so that
/// success / warning / info colours harmonise with the active brand palette.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  final Color success;
  final Color warning;
  final Color info;

  const AppSemanticColors({
    required this.success,
    required this.warning,
    required this.info,
  });

  @override
  AppSemanticColors copyWith({Color? success, Color? warning, Color? info}) {
    return AppSemanticColors(
      success: success ?? this.success,
      warning: warning ?? this.warning,
      info: info ?? this.info,
    );
  }

  @override
  AppSemanticColors lerp(AppSemanticColors? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
    );
  }
}

/// Resolves a notification `severity` string to a display colour.
///
/// The console raises a `console_broadcast` at one of three severities; this
/// keeps an urgent announcement visually distinct from a routine one:
///   * `warning` → [AppSemanticColors.warning]
///   * `alert`   → [ColorScheme.error] (there is no semantic "alert" token —
///                 an alert is the strongest signal, so it borrows error)
///   * `info` (and any unknown value) → [AppSemanticColors.info]
///
/// Lives here — not inlined in the card — so OS-push rendering and the in-app
/// card resolve severity to the same colour. The app always installs
/// [AppSemanticColors], so the lookup is non-null.
Color severityColor(BuildContext context, String severity) {
  final semantic = Theme.of(context).extension<AppSemanticColors>()!;
  switch (severity) {
    case 'warning':
      return semantic.warning;
    case 'alert':
      return Theme.of(context).colorScheme.error;
    case 'info':
    default:
      return semantic.info;
  }
}
