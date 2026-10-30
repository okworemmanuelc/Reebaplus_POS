import 'package:flutter/material.dart';

import 'package:reebaplus_pos/features/settings/screens/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The page of a full-screen subscription state (Wave 2 B, #414): a plain
/// Scaffold on the redesign page background (no blurred photo), the content
/// centred at the settings 720 cap (raw, not `getRSize`), a hero in the middle
/// and the actions pinned under it. Scrolls when the space is short, so a
/// sideways phone or a 1.3 text scale never overflows. Shared-part candidate.
class SubscriptionStateFrame extends StatelessWidget {
  const SubscriptionStateFrame({
    super.key,
    required this.hero,
    required this.actions,
  });

  /// Icon, title, body and any detail card — centred in the free space.
  final Widget hero;

  /// The buttons under the hero.
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final gutter = context.getRSize(24);
    final vertical = context.getRSize(32);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: DecoratedBox(
        decoration: AppDecorations.pageBackground(context),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: gutter,
                  vertical: vertical,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: kSettingsMaxContentWidth,
                      minHeight: constraints.maxHeight - vertical * 2,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Spacer(),
                          hero,
                          const Spacer(),
                          SizedBox(height: context.getRSize(28)),
                          actions,
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
