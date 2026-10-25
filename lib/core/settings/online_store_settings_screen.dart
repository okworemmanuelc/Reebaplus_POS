import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/online_store_detail_screen.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// "Business · LGA" — how shoppers see a store (PRD #421, e.g. "Stallion
/// Global · Nasarawa"). Falls back to the business name alone.
String onlineStoreDisplayName({required String? businessName, required StoreData store}) {
  final name = (businessName ?? '').trim().isEmpty ? store.name : businessName!.trim();
  final lga = store.lga?.trim() ?? '';
  return lga.isEmpty ? name : '$name · $lga';
}

/// Settings → Online store (#423). Lists every store (never vans) with its
/// online status; each row opens that store's online page. Gated by
/// [Gates.manageOnlineStore] (`stores.online_ordering`, CEO by default).
class OnlineStoreSettingsScreen extends ConsumerStatefulWidget {
  const OnlineStoreSettingsScreen({super.key});

  @override
  ConsumerState<OnlineStoreSettingsScreen> createState() =>
      _OnlineStoreSettingsScreenState();
}

class _OnlineStoreSettingsScreenState
    extends ConsumerState<OnlineStoreSettingsScreen> {
  late final Stream<List<StoreData>> _stores;

  @override
  void initState() {
    super.initState();
    _stores = ref.read(databaseProvider).storesDao.watchActiveStores();
  }

  @override
  Widget build(BuildContext context) {
    final canManage = Gates.manageOnlineStore.allows(ref);
    final businessName = ref.watch(currentBusinessProvider)?.name;
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: StoresTopBar(
          height: storesTopBarHeight(context),
          header: ScreenHeader(
            leading: StoresBackButton(onPressed: () => Navigator.maybePop(context)),
            icon: AppIcons.public,
            title: 'Online store',
          ),
        ),
        body: !canManage
            ? const StoresMessage(
                key: Key('online-store-no-access'),
                text: 'You don\'t have access to the online store settings.',
              )
            : StreamBuilder<List<StoreData>>(
                stream: _stores,
                builder: (context, snap) {
                  if (!snap.hasData) return const SizedBox.shrink();
                  final stores = withoutVans(snap.data!);
                  return CustomScrollView(
                    key: const Key('online-store-list'),
                    slivers: [
                      storesSliver(
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const StoresNotice(
                                text: 'Switch a store online to list it for shoppers in '
                                    'the areas it delivers to. Vans are never listed.',
                              ),
                              SizedBox(height: context.getRSize(16)),
                              if (stores.isEmpty)
                                const StoresMessage(text: 'No stores yet.'),
                              for (final store in stores) ...[
                                OnlineStoreRow(
                                  key: ValueKey('online-store-row-${store.id}'),
                                  title: store.name,
                                  subtitle: (store.lga ?? '').trim().isEmpty
                                      ? 'Area not set'
                                      : onlineStoreDisplayName(
                                          businessName: businessName, store: store),
                                  online: store.onlineOrderingEnabled,
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          OnlineStoreDetailScreen(storeId: store.id),
                                    ),
                                  ),
                                ),
                                SizedBox(height: context.getRSize(12)),
                              ],
                            ],
                          ),
                        ),
                        top: context.getRSize(16),
                        bottom: context.getRSize(24) + context.deviceBottomPadding,
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

/// One store in the hub: name, "Business · LGA", and an Online/Offline pill.
class OnlineStoreRow extends StatelessWidget {
  const OnlineStoreRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.online,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool online;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(12)),
              child: Row(
                children: [
                  const IconTile(icon: AppIcons.store, tone: IconTileTone.green, size: 40),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.regularStyle(12).copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  TagPill(
                    label: online ? 'Online' : 'Offline',
                    tone: online ? TagPillTone.green : TagPillTone.neutral,
                  ),
                  Icon(AppIcons.chevronRight, color: muted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
