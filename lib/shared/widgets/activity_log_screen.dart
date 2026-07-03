import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/models/activity_log.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/inventory/data/inventory_data.dart';
import 'package:reebaplus_pos/features/stores/data/models/store.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

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

    final bgCol = Theme.of(context).scaffoldBackgroundColor;
    final surfaceCol = Theme.of(context).colorScheme.surface;
    final textCol = Theme.of(context).colorScheme.onSurface;
    final subtextCol =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final borderCol = Theme.of(context).dividerColor;
    final cardCol = Theme.of(context).cardColor;

    return Scaffold(
      backgroundColor: bgCol,
      appBar: AppBar(
        backgroundColor: surfaceCol,
        elevation: 0,
        leading: Builder(
          builder: (ctx) => InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Scaffold.of(ctx).openDrawer(),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 2.5,
                    width: context.getRSize(22),
                    decoration: BoxDecoration(
                      color: textCol,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Container(
                    height: 2.5,
                    width: context.getRSize(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Container(
                    height: 2.5,
                    width: context.getRSize(22),
                    decoration: BoxDecoration(
                      color: textCol,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        title: Row(
          children: [
            Container(
              padding: EdgeInsets.all(context.getRSize(8)),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Theme.of(context).colorScheme.secondary,
                    Theme.of(context).colorScheme.primary,
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                FontAwesomeIcons.clockRotateLeft.data,
                color: Theme.of(context).colorScheme.onPrimary,
                size: context.getRSize(16),
              ),
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Activity Logs',
                      style: TextStyle(
                        fontSize: context.getRFontSize(18),
                        fontWeight: FontWeight.w800,
                        color: textCol,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  Text(
                    ref.watch(activeStoreLabelProvider),
                    style: TextStyle(
                      fontSize: context.getRFontSize(11),
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          const NotificationBell(),
          SizedBox(width: context.getRSize(8)),
        ],
      ),
      drawer: const AppDrawer(activeRoute: 'activity_logs'),
      body: Column(
        children: [
          Expanded(
            child: Builder(
              builder: (context) {
                final desiredStoreId = ref.watch(lockedStoreProvider).value;
                final state = ref.watch(paginatedActivityLogsProvider(desiredStoreId));

                if (state.isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (state.logs.isEmpty) {
                  return AppRefreshWrapper(
                    onRefresh: () => ref
                        .invalidate(paginatedActivityLogsProvider(desiredStoreId)),
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: Container(
                        height: MediaQuery.of(context).size.height - kToolbarHeight - 100,
                        alignment: Alignment.center,
                        child: _buildEmptyState(context, textCol, subtextCol, desiredStoreId),
                      ),
                    ),
                  );
                }

                return AppRefreshWrapper(
                  onRefresh: () => ref
                      .invalidate(paginatedActivityLogsProvider(desiredStoreId)),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: context
                        .rPadding(16)
                        .add(
                          EdgeInsets.only(bottom: context.deviceBottomPadding),
                        ),
                    itemCount: state.logs.length + (state.isLoadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (state.hasMore && !state.isLoadingMore && index >= state.logs.length - 5) {
                        Future.microtask(() {
                          if (context.mounted) {
                            ref.read(paginatedActivityLogsProvider(desiredStoreId).notifier).loadMore();
                          }
                        });
                      }

                      if (index == state.logs.length) {
                        return Padding(
                          padding: EdgeInsets.symmetric(vertical: context.getRSize(16)),
                          child: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }

                      final log = state.logs[index];
                      return Padding(
                        padding: EdgeInsets.only(bottom: context.getRSize(12)),
                        child: _buildLogCard(
                          context,
                          log,
                          cardCol,
                          surfaceCol,
                          textCol,
                          subtextCol,
                          borderCol,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    Color textCol,
    Color subtextCol,
    String? storeId,
  ) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: context.rPadding(20),
            decoration: BoxDecoration(
              color: textCol.withValues(alpha: 0.05),
              shape: BoxShape.circle,
            ),
            child: Icon(
              FontAwesomeIcons.clockRotateLeft.data,
              size: context.getRSize(48),
              color: subtextCol.withValues(alpha: 0.5),
            ),
          ),
          SizedBox(height: context.getRSize(24)),
          Text(
            'No Activity Found',
            style: TextStyle(
              fontSize: context.getRFontSize(18),
              fontWeight: FontWeight.bold,
              color: textCol,
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            storeId == null
                ? 'Actions performed in the app will appear here.'
                : 'No activity found for the selected store.',
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              color: subtextCol,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogCard(
    BuildContext context,
    ActivityLog log,
    Color cardCol,
    Color surfaceCol,
    Color textCol,
    Color subtextCol,
    Color borderCol,
  ) {
    // Determine the icon and color based on the action or type
    final scheme = Theme.of(context).colorScheme;
    final semantic = Theme.of(context).extension<AppSemanticColors>();
    final actionLower = log.action.toLowerCase();
    IconData icon = FontAwesomeIcons.bolt.data;
    Color iconColor = scheme.primary;

    if (actionLower.contains('order') ||
        actionLower.contains('pos') ||
        actionLower.contains('sale')) {
      icon = FontAwesomeIcons.cashRegister.data;
      iconColor = semantic?.success ?? success;
    } else if (actionLower.contains('inventory') ||
        actionLower.contains('stock') ||
        actionLower.contains('delivery')) {
      icon = FontAwesomeIcons.boxesStacked.data;
      iconColor = semantic?.warning ?? const Color(0xFFF59E0B); // amber
    } else if (actionLower.contains('customer')) {
      icon = FontAwesomeIcons.user.data;
      iconColor = const Color(0xFF8B5CF6); // purple
    }

    return Container(
      decoration: BoxDecoration(
        color: surfaceCol,
        borderRadius: BorderRadius.circular(context.getRSize(16)),
        border: Border.all(color: borderCol),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: context.rPadding(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: context.rPadding(12),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(context.getRSize(12)),
              ),
              child: Icon(icon, size: context.getRSize(18), color: iconColor),
            ),
            SizedBox(width: context.getRSize(16)),
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
                          style: TextStyle(
                            fontSize: context.getRFontSize(15),
                            fontWeight: FontWeight.w700,
                            color: textCol,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _formatTimeAgo(log.timestamp),
                        style: TextStyle(
                          fontSize: context.getRFontSize(12),
                          fontWeight: FontWeight.w600,
                          color: subtextCol,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    log.description,
                    style: TextStyle(
                      fontSize: context.getRFontSize(13.5),
                      height: 1.4,
                      color: subtextCol,
                    ),
                  ),
                  SizedBox(height: context.getRSize(8)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        DateFormat('MMM d, y • h:mm a').format(log.timestamp),
                        style: TextStyle(
                          fontSize: context.getRFontSize(11),
                          fontWeight: FontWeight.w500,
                          color: subtextCol.withValues(alpha: 0.5),
                        ),
                      ),
                      if (log.storeId != null)
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: context.getRSize(6),
                            vertical: context.getRSize(2),
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            kStores
                                .firstWhere(
                                  (w) => w.id == log.storeId,
                                  orElse: () =>
                                      Store(id: '', name: 'N/A', location: ''),
                                )
                                .name,
                            style: TextStyle(
                              fontSize: context.getRFontSize(10),
                              fontWeight: FontWeight.bold,
                              color: scheme.primary,
                            ),
                          ),
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
