import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/models/notification.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/features/orders/screens/crate_return_approval_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

class NotificationsModal extends ConsumerWidget {
  const NotificationsModal({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const NotificationsModal(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(databaseProvider);
    final notifService = ref.read(notificationProvider);
    // Watch (not read) so the modal rebuilds when AuthService.value flips
    // to null mid-logout; the sync stream below would otherwise re-build a
    // tenant-scoped query and trip requireBusinessId().
    final loggedIn = ref.watch(authProvider).currentUser != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context),
      child: DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.5,
        maxChildSize: 0.9,
        snap: true,
        snapSizes: const [0.5, 0.9],
        builder: (context, scrollController) {
          return GestureDetector(
            onTap: () {}, // Prevent tap from reaching the barrier
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: Column(
                children: [
                  // Handle
                  Padding(
                    padding: EdgeInsets.only(top: context.getRSize(12)),
                    child: Container(
                      width: context.getRSize(40),
                      height: context.getRSize(4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).dividerColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Header
                  _buildHeader(context, ref: ref),

                  // Sync Status Banner — gated on auth: the inline DAO stream
                  // builds a fresh tenant-scoped query on every rebuild and
                  // would otherwise hit requireBusinessId() during logout.
                  if (!loggedIn)
                    const SizedBox.shrink()
                  else StreamBuilder<int>(
                    stream: db.syncDao.watchPendingCount(),
                    builder: (context, snap) {
                      final count = snap.data ?? 0;
                      if (count == 0) return const SizedBox.shrink();

                      return Container(
                        width: double.infinity,
                        margin: EdgeInsets.symmetric(
                          horizontal: context.getRSize(20),
                          vertical: context.getRSize(8),
                        ),
                        padding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(16),
                          vertical: context.getRSize(12),
                        ),
                        decoration: BoxDecoration(
                          color: blueMain.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: blueMain.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: context.getRSize(14),
                              height: context.getRSize(14),
                              child: const CircularProgressIndicator(
                                strokeWidth: 2,
                                color: blueMain,
                              ),
                            ),
                            SizedBox(width: context.getRSize(12)),
                            Expanded(
                              child: Text(
                                'Syncing $count file${count == 1 ? '' : 's'} to cloud...',
                                style: TextStyle(
                                  color: blueMain,
                                  fontSize: context.getRFontSize(13),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              'Background',
                              style: TextStyle(
                                color:
                                    Theme.of(
                                      context,
                                    ).textTheme.bodySmall?.color ??
                                    Theme.of(
                                      context,
                                    ).iconTheme.color!.withValues(alpha: 0.6),
                                fontSize: context.getRFontSize(11),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                  Divider(height: 1, color: Theme.of(context).dividerColor),
                  // List
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: notifService,
                      builder: (context, notifications, _) {
                        if (notifications.isEmpty) {
                          return _buildEmptyState(context);
                        }
                        return ListView.separated(
                          controller: scrollController,
                          padding: EdgeInsets.all(context.getRSize(16)).add(
                            EdgeInsets.only(bottom: context.deviceBottomPadding),
                          ),
                          itemCount: notifications.length,
                          separatorBuilder: (context, index) =>
                              SizedBox(height: context.getRSize(12)),
                          itemBuilder: (context, index) {
                            final n = notifications[index];
                            return _NotificationCard(notification: n);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader(BuildContext context, {required WidgetRef ref}) {
    return Padding(
      padding: EdgeInsets.all(context.getRSize(20)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                FontAwesomeIcons.bell,
                size: context.getRSize(20),
                color: blueMain,
              ),
              SizedBox(width: context.getRSize(12)),
              Text(
                'Notifications',
                style: TextStyle(
                  fontSize: context.getRFontSize(18),
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          AppButton(
            text: 'Dismiss All',
            variant: AppButtonVariant.danger,
            isFullWidth: false,
            height: context.getRSize(36),
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(12)),
            onPressed: () {
              ref.read(notificationProvider).clearAll();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            FontAwesomeIcons.bellSlash,
            size: context.getRSize(48),
            color: Theme.of(context).dividerColor,
          ),
          SizedBox(height: context.getRSize(16)),
          Text(
            'No notifications yet',
            style: TextStyle(
              color:
                  Theme.of(context).textTheme.bodySmall?.color ??
                  Theme.of(context).iconTheme.color!,
              fontSize: context.getRFontSize(16),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationCard extends ConsumerWidget {
  final NotificationModel notification;

  const _NotificationCard({required this.notification});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Color cardBg = Theme.of(context).cardColor;
    final Color textCol = Theme.of(context).colorScheme.onSurface;
    final Color subtextCol =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final Color borderCol = Theme.of(context).dividerColor;

    final IconData icon = _getIconForType(notification.type);
    final Color iconColor = _getColorForType(notification.type);

    return GestureDetector(
      onTap: notification.type == 'product_update'
          ? () => _showProductUpdateSummary(context, notification, ref)
          : notification.type == 'crate_short_return'
              ? () => _openCrateReturnApproval(context, notification, ref)
              : null,
      child: Container(
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderCol),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(context.getRSize(10)),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: context.getRSize(16)),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    notification.message,
                    style: TextStyle(
                      color: textCol,
                      fontSize: context.getRFontSize(14),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    DateFormat('MMM d, h:mm a').format(notification.timestamp),
                    style: TextStyle(
                      color: subtextCol,
                      fontSize: context.getRFontSize(12),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.close,
                size: context.getRSize(18),
                color: subtextCol,
              ),
              onPressed: () {
                ref.read(notificationProvider).deleteNotification(notification.id);
              },
            ),
          ],
        ),
      ), // Container
    ); // GestureDetector
  }

  void _showProductUpdateSummary(
    BuildContext context,
    NotificationModel notification,
    WidgetRef ref,
  ) {
    ref.read(notificationProvider).markAsRead(notification.id);
    Map<String, dynamic> data = {};
    try {
      data =
          jsonDecode(notification.linkedRecordId ?? '{}')
              as Map<String, dynamic>;
    } catch (_) {}

    final product = data['product'] as String? ?? 'Unknown product';
    final manager = data['manager'] as String? ?? 'Unknown';
    final summary = data['summary'] as String? ?? notification.message;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(
              FontAwesomeIcons.penToSquare,
              size: 16,
              color: Color(0xFFF5A623),
            ),
            SizedBox(width: 8),
            Text('Product Update'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _summaryRow(ctx, 'Product', product),
            const SizedBox(height: 8),
            _summaryRow(ctx, 'Updated by', manager),
            const SizedBox(height: 12),
            Text(summary, style: const TextStyle(fontSize: 14)),
          ],
        ),
        actions: [
          AppButton(
            text: 'Dismiss',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(BuildContext context, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ],
    );
  }

  IconData _getIconForType(String type) {
    switch (type) {
      case 'new_order':
        return FontAwesomeIcons.receipt;
      case 'low_stock':
        return FontAwesomeIcons.triangleExclamation;
      case 'large_expense':
        return FontAwesomeIcons.fileInvoiceDollar;
      case 'new_delivery':
        return FontAwesomeIcons.truckRampBox;
      case 'failed_transaction':
        return FontAwesomeIcons.circleExclamation;
      case 'product_update':
        return FontAwesomeIcons.penToSquare;
      case 'crate_short_return':
        return FontAwesomeIcons.boxOpen;
      case 'crate_return_approved':
        return FontAwesomeIcons.circleCheck;
      case 'crate_return_rejected':
        return FontAwesomeIcons.circleXmark;
      case 'stock_approval.requested':
        return FontAwesomeIcons.clipboardList;
      case 'stock_approval.approved':
        return FontAwesomeIcons.circleCheck;
      case 'stock_approval.rejected':
        return FontAwesomeIcons.circleXmark;
      case 'staff.invited':
        return FontAwesomeIcons.userPlus;
      case 'staff.suspended':
        return FontAwesomeIcons.userSlash;
      case 'staff.reactivated':
        return FontAwesomeIcons.userCheck;
      case 'staff.role_changed':
        return FontAwesomeIcons.userGear;
      case 'staff.profile_updated':
        return FontAwesomeIcons.userPen;
      default:
        return FontAwesomeIcons.bell;
    }
  }

  Color _getColorForType(String type) {
    switch (type) {
      case 'new_order':
        return success;
      case 'low_stock':
        return const Color(0xFFF59E0B);
      case 'large_expense':
        return danger;
      case 'new_delivery':
        return blueMain;
      case 'failed_transaction':
        return danger;
      case 'product_update':
        return const Color(0xFFF5A623);
      case 'crate_short_return':
        return const Color(0xFFF5A623);
      case 'crate_return_approved':
        return success;
      case 'crate_return_rejected':
        return danger;
      case 'stock_approval.requested':
        return const Color(0xFFF5A623);
      case 'stock_approval.approved':
        return success;
      case 'stock_approval.rejected':
        return danger;
      case 'staff.invited':
        return blueMain;
      case 'staff.suspended':
        return danger;
      case 'staff.reactivated':
        return success;
      case 'staff.role_changed':
        return blueMain;
      case 'staff.profile_updated':
        return blueMain;
      default:
        return blueMain;
    }
  }

  void _openCrateReturnApproval(
      BuildContext context, NotificationModel notification, WidgetRef ref) {
    final pendingReturnId = notification.linkedRecordId;
    final notifId = notification.id;
    if (pendingReturnId == null || pendingReturnId.isEmpty) return;
    ref.read(notificationProvider).markAsRead(notification.id);
    Navigator.pop(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CrateReturnApprovalScreen(
          pendingReturnId: pendingReturnId,
          notificationId: notifId,
        ),
      ),
    );
  }
}
