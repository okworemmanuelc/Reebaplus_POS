import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// The persona-aware first-run empty body shared by the POS, Inventory, and
/// reachable screens (Seam 2 — issue #34, ADR 0006, issue #231). Empty screens
/// hand their empty state to this widget, which reads [firstRunSurfaceStateProvider]
/// and renders the one surface that fits the user:
///
/// - `createStoreCta` → a primary "Create a store" button that navigates to the
///   Stores tab (for owners when business has zero stores).
/// - `addProductCta` → a primary "Add your first product" button that opens the
///   Fast-Add form (`AddProductScreen` in direct, non-receive mode — #30).
/// - `neutralEmpty` → a no-button "a manager can add them" message, for users
///   who lack store/product creation permissions.
/// - `skeleton` → nothing here (the tab shows its own first-load skeleton at a
///   higher level; this only guards against a CTA flash — invariant #11).
/// - `hasContent` → nothing (the catalogue has products; the grid renders).
class FirstRunEmptyState extends ConsumerWidget {
  const FirstRunEmptyState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surface = ref.watch(firstRunSurfaceStateProvider);
    final lex = ref.watch(industryLexiconProvider);
    final theme = Theme.of(context);
    final subtext =
        theme.textTheme.bodySmall?.color ?? theme.iconTheme.color!;

    switch (surface) {
      case FirstRunSurfaceState.hasContent:
      case FirstRunSurfaceState.skeleton:
        // The grid / the tab-level skeleton owns these; render nothing so no
        // CTA ever flashes over a streaming catalogue.
        return const SizedBox.shrink();

      case FirstRunSurfaceState.createStoreCta:
        return _EmptyMessage(
          icon: FontAwesomeIcons.store.data,
          title: 'No stores yet',
          subtitle: 'Create a store to start adding products and selling.',
          subtext: subtext,
          action: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: context.getRSize(280)),
            child: AppButton(
              text: 'Create a store',
              icon: FontAwesomeIcons.plus.data,
              onPressed: () {
                Navigator.of(context).popUntil((route) => route.isFirst);
                NavigationService().setIndex(NavigationService.storesTab);
              },
            ),
          ),
        );

      case FirstRunSurfaceState.neutralEmpty:
        return _EmptyMessage(
          icon: FontAwesomeIcons.boxOpen.data,
          title: 'No ${lex.itemPluralLower} yet',
          subtitle: 'A manager can add them.',
          subtext: subtext,
        );

      case FirstRunSurfaceState.addProductCta:
        return _EmptyMessage(
          icon: FontAwesomeIcons.boxOpen.data,
          title: 'No ${lex.itemPluralLower} yet',
          subtitle: 'Add your first ${lex.itemLower} to start selling.',
          subtext: subtext,
          action: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: context.getRSize(280)),
            child: AppButton(
              text: 'Add your first ${lex.itemLower}',
              icon: FontAwesomeIcons.plus.data,
              onPressed: () => Navigator.of(context).push(
                // Direct (non-receive) mode — the Fast-Add form (#30).
                MaterialPageRoute(builder: (_) => const AddProductScreen()),
              ),
            ),
          ),
        );
    }
  }
}

/// The shared centered empty-state layout: icon, title, subtitle, and an
/// optional action button below.
class _EmptyMessage extends StatelessWidget {
  const _EmptyMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.subtext,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color subtext;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.getRSize(32)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: context.getRSize(48),
              color: subtext.withValues(alpha: 0.3),
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.getRFontSize(16),
                color: subtext,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                color: subtext.withValues(alpha: 0.8),
              ),
            ),
            if (action != null) ...[
              SizedBox(height: context.getRSize(24)),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
