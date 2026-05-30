import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';

/// CEO Settings > Stores (§10.1). Read-only this phase: shows the business's
/// store(s). Adding more stores is Phase 2.
///
/// Note: the `stores` table holds only `name` + a single `location` string
/// (onboarding fuses street/state/country into it), so there are no separate
/// address/state/country fields to show here.
class StoresSettingsScreen extends ConsumerWidget {
  const StoresSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final stores = ref.watch(allStoresProvider);

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Stores',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: stores.when(
        loading: () => const SizedBox.shrink(),
        error: (_, __) => Center(
          child: Text(
            'Couldn\'t load stores.',
            style: TextStyle(
              color: t.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        data: (list) => SettingsFadeIn(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              for (final store in list) ...[
                SettingsTile(
                  icon: Icons.store_rounded,
                  title: store.name,
                  subtitle: (store.location?.trim().isNotEmpty ?? false)
                      ? store.location!.trim()
                      : 'No address set',
                ),
                const SizedBox(height: 16),
              ],
              const SizedBox(height: 8),
              Text(
                'Adding more stores is coming in a future update.',
                style: TextStyle(
                  fontSize: 13,
                  color: t.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
