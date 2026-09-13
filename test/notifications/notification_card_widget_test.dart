import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/shared/models/notification.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';

// Slice 3 of #138: a `console_broadcast` card is colour-coded by its severity
// (info / warning / alert) and shows a megaphone, while every other type keeps
// its existing icon + colour. Pumps NotificationCard directly
// (visibleForTesting) under the real AppTheme so the AppSemanticColors
// extension that severityColor() reads is present.
void main() {
  final theme = AppTheme.light();
  final semantic = theme.extension<AppSemanticColors>()!;

  NotificationModel notif(String type, {String severity = 'info'}) =>
      NotificationModel(
        id: 'n1',
        type: type,
        message: 'Head office announcement',
        timestamp: DateTime(2026, 7, 13, 9, 0),
        severity: severity,
      );

  Future<void> pumpCard(WidgetTester tester, NotificationModel n) {
    return tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: theme,
          home: Scaffold(body: NotificationCard(notification: n)),
        ),
      ),
    );
  }

  // The leading icon is the only Icon carrying this IconData (the trailing
  // close button is Icons.close), so byIcon resolves it unambiguously.
  Icon iconWidget(WidgetTester tester, IconData data) =>
      tester.widget<Icon>(find.byIcon(data));

  group('console_broadcast severity rendering', () {
    testWidgets('alert → megaphone + error colour', (tester) async {
      await pumpCard(tester, notif('console_broadcast', severity: 'alert'));

      expect(find.byIcon(FontAwesomeIcons.bullhorn.data), findsOneWidget);
      expect(
        iconWidget(tester, FontAwesomeIcons.bullhorn.data).color,
        theme.colorScheme.error,
      );
    });

    testWidgets('warning → megaphone + warning colour', (tester) async {
      await pumpCard(tester, notif('console_broadcast', severity: 'warning'));

      expect(find.byIcon(FontAwesomeIcons.bullhorn.data), findsOneWidget);
      expect(
        iconWidget(tester, FontAwesomeIcons.bullhorn.data).color,
        semantic.warning,
      );
    });

    testWidgets('info → megaphone + info colour', (tester) async {
      await pumpCard(tester, notif('console_broadcast', severity: 'info'));

      expect(find.byIcon(FontAwesomeIcons.bullhorn.data), findsOneWidget);
      expect(
        iconWidget(tester, FontAwesomeIcons.bullhorn.data).color,
        semantic.info,
      );
    });
  });

  testWidgets('non-broadcast type keeps its existing icon + colour', (
    tester,
  ) async {
    // new_order = receipt icon in the success colour. Severity is deliberately
    // 'alert' to prove it is ignored for non-broadcast types and the megaphone
    // never appears (regression guard for the other notification types).
    await pumpCard(tester, notif('new_order', severity: 'alert'));

    expect(find.byIcon(FontAwesomeIcons.bullhorn.data), findsNothing);
    expect(find.byIcon(FontAwesomeIcons.receipt.data), findsOneWidget);
    expect(
      iconWidget(tester, FontAwesomeIcons.receipt.data).color,
      semantic.success,
    );
  });
}
