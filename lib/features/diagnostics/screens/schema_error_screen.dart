import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/diagnostics/schema_audit.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/section_header.dart';

/// The widest the content gets on a tablet (the app-wide 720 for list and form
/// screens). Repeated here as a literal: the shared constant lives in the
/// Settings screen, whose imports pull in the providers this screen must not
/// depend on.
const double _kContentMaxWidth = 720;

/// Refuse-to-boot screen shown when [SchemaAudit] detects unhealable schema
/// drift. Surfaces the diagnostic file path so support can ask the user to
/// share it. The "Retry" button kills the app — the next launch re-runs
/// `beforeOpen`, which gives heal another shot.
///
/// Launched with a bare `runApp` before `ProviderScope`, the theme controller
/// or the router exist, so it owns its `MaterialApp` and uses only pure theme
/// code (`AppTheme.dark()` is a synchronous static [ThemeData]: bundled font,
/// no providers, no preferences). It stays dark-only, as it always was (#443).
class SchemaErrorScreen extends StatelessWidget {
  final SchemaAuditResult audit;

  const SchemaErrorScreen({super.key, required this.audit});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: _SchemaErrorBody(audit: audit),
    );
  }
}

class _SchemaErrorBody extends StatelessWidget {
  final SchemaAuditResult audit;

  const _SchemaErrorBody({required this.audit});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final gap = context.getRSize(12);

    Widget block(String? title, List<Widget> children) => Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: AppDecorations.card(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              SectionHeader(title: title, variant: SectionHeaderVariant.group),
              SizedBox(height: context.getRSize(6)),
            ],
            ...children,
          ],
        ),
      ),
    );

    Widget line(String text) => Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(2)),
      child: Text(
        text,
        style: context
            .regularStyle(13)
            .copyWith(color: t.colorScheme.onSurface),
      ),
    );

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(20)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const IconTile(
                        icon: AppIcons.warning,
                        tone: IconTileTone.danger,
                        size: 56,
                      ),
                      SizedBox(width: context.getRSize(14)),
                      Expanded(
                        child: Text(
                          'Schema corruption detected',
                          style: context
                              .extraBoldStyle(22)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(12)),
                  Text(
                    'The local database is missing columns or tables that the '
                    'app requires. The app could not automatically repair the '
                    'issue. Please contact support and share the diagnostic '
                    'file below.',
                    style: context
                        .regularStyle(14)
                        .copyWith(color: muted, height: 1.4),
                  ),
                  SizedBox(height: context.getRSize(16)),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          block(null, [
                            _kv(
                              context,
                              'Schema version',
                              '${audit.schemaVersion}',
                            ),
                            _kv(
                              context,
                              'Audited at',
                              audit.ranAt.toIso8601String(),
                            ),
                            if (audit.businessId != null)
                              _kv(
                                context,
                                'Business ID',
                                '${audit.businessId}',
                              ),
                            if (audit.deviceUserId != null)
                              _kv(
                                context,
                                'Device user ID',
                                '${audit.deviceUserId}',
                              ),
                          ]),
                          if (audit.missingTables.isNotEmpty)
                            block('Missing tables', [
                              for (final t in audit.missingTables)
                                line(
                                  '• ${t.table}'
                                  '${t.healed ? "  (healed)" : ""}'
                                  '${t.healError != null ? "  — ${t.healError}" : ""}',
                                ),
                            ]),
                          if (audit.missingColumns.isNotEmpty)
                            block('Missing columns', [
                              for (final c in audit.missingColumns)
                                line(
                                  '• ${c.table}.${c.expectedColumn} '
                                  '(${c.expectedType})'
                                  '${c.healed ? "  (healed)" : ""}'
                                  '${c.healError != null ? "  — ${c.healError}" : ""}',
                                ),
                            ]),
                          if (audit.recentMigrationEvents.isNotEmpty)
                            block('Recent migration events', [
                              for (final ev in audit.recentMigrationEvents)
                                line(
                                  '• v${ev.version} ${ev.step} [${ev.severity}]'
                                  '${ev.errorMessage != null ? "  — ${ev.errorMessage}" : ""}',
                                ),
                            ]),
                          if (audit.reportPath != null)
                            block('Diagnostic report', [
                              SelectableText(
                                audit.reportPath!,
                                style: context.monoStyle.copyWith(
                                  fontSize: context.getRFontSize(12),
                                  color: t.colorScheme.onSurface,
                                ),
                              ),
                              SizedBox(height: context.getRSize(10)),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: IntrinsicWidth(
                                  child: AppButton(
                                    text: 'Copy report path',
                                    icon: AppIcons.copy,
                                    variant: AppButtonVariant.outline,
                                    size: AppButtonSize.small,
                                    height: kMinInteractiveDimension,
                                    isFullWidth: false,
                                    onPressed: () {
                                      Clipboard.setData(
                                        ClipboardData(text: audit.reportPath!),
                                      );
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Path copied to clipboard',
                                          ),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ]),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: context.getRSize(12)),
                  AppButton(
                    text: 'Close app',
                    variant: AppButtonVariant.danger,
                    onPressed: () {
                      // Closing the app forces a cold restart, which re-runs
                      // beforeOpen and gives heal another attempt.
                      SystemNavigator.pop();
                      if (Platform.isAndroid) {
                        // SystemNavigator.pop is a no-op on iOS; on Android it
                        // exits cleanly. As a fallback we exit the isolate.
                      } else {
                        exit(0);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(2)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: context.getRSize(130),
            child: Text(
              k,
              style: context.mediumStyle(13).copyWith(color: muted),
            ),
          ),
          Expanded(
            child: SelectableText(
              v,
              // Versions, timestamps and ids are codes: the mono family.
              style: context.monoStyle.copyWith(
                fontSize: context.getRFontSize(12),
                color: t.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
