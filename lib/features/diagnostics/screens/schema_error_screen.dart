import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/diagnostics/schema_audit.dart';

/// Refuse-to-boot screen shown when [SchemaAudit] detects unhealable schema
/// drift. Surfaces the diagnostic file path so support can ask the user to
/// share it. The "Retry" button kills the app — the next launch re-runs
/// `beforeOpen`, which gives heal another shot.
class SchemaErrorScreen extends StatelessWidget {
  final SchemaAuditResult audit;

  const SchemaErrorScreen({super.key, required this.audit});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 56,
                  color: Colors.amber,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Schema corruption detected',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'The local database is missing columns or tables that the app '
                  'requires. The app could not automatically repair the issue. '
                  'Please contact support and share the diagnostic file below.',
                  style: TextStyle(fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _kv('Schema version', '${audit.schemaVersion}'),
                        _kv('Audited at', audit.ranAt.toIso8601String()),
                        if (audit.businessId != null)
                          _kv('Business ID', '${audit.businessId}'),
                        if (audit.deviceUserId != null)
                          _kv('Device user ID', '${audit.deviceUserId}'),
                        const SizedBox(height: 12),
                        if (audit.missingTables.isNotEmpty) ...[
                          const Text(
                            'Missing tables',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          for (final t in audit.missingTables)
                            Text(
                              '• ${t.table}'
                              '${t.healed ? "  (healed)" : ""}'
                              '${t.healError != null ? "  — ${t.healError}" : ""}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          const SizedBox(height: 12),
                        ],
                        if (audit.missingColumns.isNotEmpty) ...[
                          const Text(
                            'Missing columns',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          for (final c in audit.missingColumns)
                            Text(
                              '• ${c.table}.${c.expectedColumn} '
                              '(${c.expectedType})'
                              '${c.healed ? "  (healed)" : ""}'
                              '${c.healError != null ? "  — ${c.healError}" : ""}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          const SizedBox(height: 12),
                        ],
                        if (audit.recentMigrationEvents.isNotEmpty) ...[
                          const Text(
                            'Recent migration events',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          for (final ev in audit.recentMigrationEvents)
                            Text(
                              '• v${ev.version} ${ev.step} [${ev.severity}]'
                              '${ev.errorMessage != null ? "  — ${ev.errorMessage}" : ""}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          const SizedBox(height: 12),
                        ],
                        if (audit.reportPath != null) ...[
                          const Text(
                            'Diagnostic report',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            audit.reportPath!,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('Copy report path'),
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: audit.reportPath!),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Path copied to clipboard'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
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
                    child: const Text('Close app'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(
            k,
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
        ),
        Expanded(
          child: SelectableText(v, style: const TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
}
