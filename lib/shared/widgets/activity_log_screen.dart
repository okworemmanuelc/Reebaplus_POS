import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/settings/settings_page_parts.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/models/activity_log.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

class ActivityLogScreen extends ConsumerStatefulWidget {
  const ActivityLogScreen({super.key});

  @override
  ConsumerState<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends ConsumerState<ActivityLogScreen> {
  @override
  Widget build(BuildContext context) {
    // §27.3 / hard rules #6 (every screen checks permissions) and #7 (hide,
    // don't grey): Activity Logs is gated to roles holding `activity_logs.view`.
    // The sidebar item is already hidden without it; this is defense-in-depth
    // against deep-links / direct navigation. Message style mirrors
    // pos_home_screen's no-access block.
    if (!Gates.viewActivityLogs.allows(ref)) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: Text(
              'You don\'t have access to Activity Logs.',
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      );
    }

    final t = Theme.of(context);
    final subtextCol = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final storeNames =
        ref.watch(storeNamesProvider).valueOrNull ?? const <String, String>{};

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: SettingsPageBar(
          height: settingsBarHeight(context),
          icon: AppIcons.history,
          title: 'Activity Logs',
          subtitle: ref.watch(activeStoreLabelProvider),
          leading: context.isRailLayout ? null : const MenuButton(),
          actions: [
            const NotificationBell(),
            SizedBox(width: context.getRSize(8)),
          ],
        ),
        // One line: test/tour/drawer_presence_ban_test.dart reads it line by line.
        // dart format off
        drawer: context.isRailLayout ? null : const AppDrawer(activeRoute: 'activity_logs'),
        // dart format on
        body: DrawerHost(
          child: Column(
            children: [
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (ref.watch(zeroStoresEmptySurfaceProvider)) {
                      return const FirstRunEmptyState();
                    }
                    final desiredStoreId = ref.watch(lockedStoreProvider).value;
                    final state = ref.watch(
                      paginatedActivityLogsProvider(desiredStoreId),
                    );

                    if (state.isLoading) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (state.logs.isEmpty) {
                      return AppRefreshWrapper(
                        onRefresh: () => ref.invalidate(
                          paginatedActivityLogsProvider(desiredStoreId),
                        ),
                        child: SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: Container(
                            height: context.screenHeight - kToolbarHeight - 100,
                            alignment: Alignment.center,
                            child: _buildEmptyState(
                              context,
                              subtextCol,
                              desiredStoreId,
                            ),
                          ),
                        ),
                      );
                    }

                    return AppRefreshWrapper(
                      onRefresh: () => ref.invalidate(
                        paginatedActivityLogsProvider(desiredStoreId),
                      ),
                      // List content caps at the raw 720 and centres; the top
                      // bar spans the full width.
                      child: SafeArea(
                        top: false,
                        bottom: false,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final gutter = settingsGutter(
                              context,
                              constraints.maxWidth,
                            );
                            return ListView.builder(
                              key: const Key('activity-log-list'),
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: EdgeInsets.fromLTRB(
                                gutter,
                                context.getRSize(16),
                                gutter,
                                context.getRSize(16) +
                                    context.deviceBottomPadding,
                              ),
                              itemCount:
                                  state.logs.length +
                                  (state.isLoadingMore ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (state.hasMore &&
                                    !state.isLoadingMore &&
                                    index >= state.logs.length - 5) {
                                  Future.microtask(() {
                                    if (context.mounted) {
                                      ref
                                          .read(
                                            paginatedActivityLogsProvider(
                                              desiredStoreId,
                                            ).notifier,
                                          )
                                          .loadMore();
                                    }
                                  });
                                }

                                if (index == state.logs.length) {
                                  return Padding(
                                    padding: EdgeInsets.symmetric(
                                      vertical: context.getRSize(16),
                                    ),
                                    child: const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  );
                                }

                                final log = state.logs[index];
                                return Padding(
                                  padding: EdgeInsets.only(
                                    bottom: context.getRSize(12),
                                  ),
                                  child: _buildLogCard(
                                    context,
                                    log,
                                    storeNames,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    Color subtextCol,
    String? storeId,
  ) {
    final t = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const IconTile(icon: AppIcons.history, tone: IconTileTone.neutral),
          SizedBox(height: context.getRSize(24)),
          Text(
            'No Activity Found',
            style: context
                .boldStyle(18)
                .copyWith(color: t.colorScheme.onSurface),
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            storeId == null
                ? 'Actions performed in the app will appear here.'
                : 'No activity found for the selected store.',
            textAlign: TextAlign.center,
            style: context.regularStyle(14).copyWith(color: subtextCol),
          ),
        ],
      ),
    );
  }

  Widget _buildLogCard(
    BuildContext context,
    ActivityLog log,
    Map<String, String> storeNames,
  ) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    // Determine the icon and tone based on the action or type.
    final actionLower = log.action.toLowerCase();
    IconData icon = AppIcons.quickSale;
    IconTileTone tone = IconTileTone.info;
    Color? tint;
    Color? ink;

    if (actionLower.contains('order') ||
        actionLower.contains('pos') ||
        actionLower.contains('sale')) {
      icon = AppIcons.pos;
      tone = IconTileTone.green;
    } else if (actionLower.contains('inventory') ||
        actionLower.contains('stock') ||
        actionLower.contains('delivery')) {
      icon = AppIcons.inventory;
      tone = IconTileTone.warning;
    } else if (actionLower.contains('customer')) {
      icon = AppIcons.user;
      final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
      tint = f.purpleTint;
      ink = f.purple;
    }

    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconTile(
              icon: icon,
              tone: tone,
              tint: tint,
              iconColor: ink,
              size: 44,
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          log.action,
                          style: context
                              .boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(width: context.getRSize(8)),
                      Text(
                        _formatTimeAgo(log.timestamp),
                        style: context.semiBoldStyle(12).copyWith(color: muted),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    log.description,
                    style: context
                        .regularStyle(13.5)
                        .copyWith(height: 1.4, color: muted),
                  ),
                  SizedBox(height: context.getRSize(8)),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: context.getRSize(8),
                    runSpacing: context.getRSize(4),
                    children: [
                      Text(
                        DateFormat('MMM d, y • h:mm a').format(log.timestamp),
                        style: context.mediumStyle(11).copyWith(color: muted),
                      ),
                      if (log.storeId != null)
                        TagPill(
                          label: storeNames[log.storeId] ?? 'N/A',
                          tone: TagPillTone.info,
                          dense: true,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimeAgo(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inSeconds < 60) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    if (difference.inDays < 7) return '${difference.inDays}d ago';
    return DateFormat('MMM d').format(timestamp);
  }
}
