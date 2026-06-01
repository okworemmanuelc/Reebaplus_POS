import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/models/activity_log.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/inventory/data/inventory_data.dart';
import 'package:reebaplus_pos/features/stores/data/models/store.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

class ActivityLogScreen extends ConsumerStatefulWidget {
  const ActivityLogScreen({super.key});

  @override
  ConsumerState<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends ConsumerState<ActivityLogScreen> {
  String? _selectedStoreId;
  final bool _loading = false;

  @override
  Widget build(BuildContext context) {
    // §27.3 / hard rules #6 (every screen checks permissions) and #7 (hide,
    // don't grey): Activity Logs is gated to roles holding `activity_logs.view`.
    // The sidebar item is already hidden without it; this is defense-in-depth
    // against deep-links / direct navigation. Message style mirrors
    // pos_home_screen's no-access block.
    if (!hasPermission(ref, 'activity_logs.view')) {
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
                          color: blueMain,
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
                    gradient: const LinearGradient(
                      colors: [blueLight, blueMain],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: blueMain.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    FontAwesomeIcons.clockRotateLeft,
                    color: Colors.white,
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
                        'System History',
                        style: TextStyle(
                          fontSize: context.getRFontSize(11),
                          color: blueMain,
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
              _buildStoreFilter(
                context,
                surfaceCol,
                textCol,
                subtextCol,
                borderCol,
              ),
              Expanded(
                child: Builder(
                  builder: (context) {
                    final logs = ref.watch(activityLogProvider).value;
                    final filteredLogs = _filterLogs(logs);

                    if (_loading) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (filteredLogs.isEmpty) {
                      return _buildEmptyState(context, textCol, subtextCol);
                    }

                    return ListView.separated(
                      padding: context.rPadding(16),
                      itemCount: filteredLogs.length,
                      separatorBuilder: (context, index) =>
                          SizedBox(height: context.getRSize(12)),
                      itemBuilder: (context, index) {
                        return _buildLogCard(
                          context,
                          filteredLogs[index],
                          cardCol,
                          surfaceCol,
                          textCol,
                          subtextCol,
                          borderCol,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
    );
  }

  Widget _buildStoreFilter(
    BuildContext context,
    Color surfaceCol,
    Color textCol,
    Color subtextCol,
    Color borderCol,
  ) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(8),
        context.getRSize(16),
        context.getRSize(16),
      ),
      decoration: BoxDecoration(
        color: surfaceCol,
        border: Border(bottom: BorderSide(color: borderCol)),
      ),
      child: AppDropdown<String?>(
        labelText: 'Filter by Store',
        value: _selectedStoreId,
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All Stores'),
          ),
          ...kStores.map((w) {
            return DropdownMenuItem<String?>(value: w.id, child: Text(w.name));
          }),
        ],
        onChanged: (val) => setState(() => _selectedStoreId = val),
      ),
    );
  }

  List<ActivityLog> _filterLogs(List<ActivityLog> logs) {
    // Lone owner sees everything. Only store filter remains.
    if (_selectedStoreId == null) return logs;

    return logs.where((log) {
      final isStoreScoped =
          log.storeId != null ||
          log.productId != null ||
          log.deliveryId != null ||
          log.orderId != null ||
          log.action.toLowerCase().contains('inventory') ||
          log.action.toLowerCase().contains('stock') ||
          log.action.toLowerCase().contains('delivery');

      if (!isStoreScoped) return true;
      return log.storeId == _selectedStoreId;
    }).toList();

  }

  Widget _buildEmptyState(
    BuildContext context,
    Color textCol,
    Color subtextCol,
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
              FontAwesomeIcons.clockRotateLeft,
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
            _selectedStoreId == null
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
    final actionLower = log.action.toLowerCase();
    IconData icon = FontAwesomeIcons.bolt;
    Color iconColor = blueMain;

    if (actionLower.contains('order') ||
        actionLower.contains('pos') ||
        actionLower.contains('sale')) {
      icon = FontAwesomeIcons.cashRegister;
      iconColor = success;
    } else if (actionLower.contains('inventory') ||
        actionLower.contains('stock') ||
        actionLower.contains('delivery')) {
      icon = FontAwesomeIcons.boxesStacked;
      iconColor = const Color(0xFFF59E0B); // amber
    } else if (actionLower.contains('customer')) {
      icon = FontAwesomeIcons.user;
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
                            color: blueMain.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            kStores
                                .firstWhere(
                                  (w) => w.id == log.storeId,
                                  orElse: () => Store(
                                    id: '',
                                    name: 'N/A',
                                    location: '',
                                  ),
                                )
                                .name,
                            style: TextStyle(
                              fontSize: context.getRFontSize(10),
                              fontWeight: FontWeight.bold,
                              color: blueMain,
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
