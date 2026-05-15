import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/dashboard/screens/approvals_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_audit_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/sales_detail_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

class ReportsHubScreen extends ConsumerStatefulWidget {
  const ReportsHubScreen({super.key});

  @override
  ConsumerState<ReportsHubScreen> createState() => _ReportsHubScreenState();
}

class _ReportsHubScreenState extends ConsumerState<ReportsHubScreen> {
  String _selectedPeriod = 'Day';
  final List<String> _periods = ['Day', 'Week', 'Month', 'Year', 'To Date'];

  bool _isDateInPeriod(DateTime date, String period) {
    final now = DateTime.now();
    final diff = now.difference(date);
    switch (period) {
      case 'Day':
        return diff.inDays == 0 && now.day == date.day;
      case 'Week':
        return diff.inDays <= 7;
      case 'Month':
        return diff.inDays <= 30;
      case 'Year':
        return diff.inDays <= 365;
      case 'To Date':
        return true;
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).currentUser;
    final isCeo = (user?.roleTier ?? 0) >= 6;

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        title: Text(
          'Business Reports',
          style: context.h3.copyWith(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        actions: [
          _buildPeriodSelector(),
          const SizedBox(width: 8),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              context.backgroundColor,
              context.backgroundColor.withValues(alpha: 0.8),
            ],
          ),
        ),
        child: GridView.count(
          crossAxisCount: 2,
          padding: EdgeInsets.all(context.spacingM),
          mainAxisSpacing: context.spacingM,
          crossAxisSpacing: context.spacingM,
          children: [
            _buildReportCard(
              context,
              title: 'Pending Approvals',
              subtitle: 'Requests Waiting',
              icon: FontAwesomeIcons.clockRotateLeft,
              color: Colors.orange,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ApprovalsScreen()),
              ),
            ),
            _buildReportCard(
              context,
              title: 'Sales Report',
              subtitle: 'Revenue & Volume',
              icon: FontAwesomeIcons.chartLine,
              color: context.primaryColor,
              locked: !isCeo,
              onTap: () {
                if (!isCeo) {
                  AppNotification.showInfo(context, 'CEO access required');
                  return;
                }
                final ordersAsync = ref.read(allOrdersProvider);
                ordersAsync.whenData((allOrders) {
                  final filtered = allOrders
                      .where((o) =>
                          o.order.status == 'completed' &&
                          _isDateInPeriod(o.order.createdAt, _selectedPeriod))
                      .toList();
                  Navigator.push(
                    context,
                    slideDownRoute(
                      SalesDetailScreen(
                        orders: filtered,
                        mode: 'sales',
                        period: _selectedPeriod,
                      ),
                    ),
                  );
                });
              },
            ),
            _buildReportCard(
              context,
              title: 'Expense Tracker',
              subtitle: 'Outflow Analysis',
              icon: FontAwesomeIcons.fileInvoiceDollar,
              color: Colors.redAccent,
              locked: !isCeo,
              onTap: () {
                if (!isCeo) {
                  AppNotification.showInfo(context, 'CEO access required');
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ExpensesScreen()),
                );
              },
            ),
            _buildReportCard(
              context,
              title: 'Stock Audit',
              subtitle: 'Inventory Health',
              icon: FontAwesomeIcons.boxesStacked,
              color: Colors.blueAccent,
              locked: !isCeo,
              onTap: () {
                if (!isCeo) {
                  AppNotification.showInfo(context, 'CEO access required');
                  return;
                }
                Navigator.push(
                  context,
                  slideDownRoute(const StockAuditScreen()),
                );
              },
            ),
            _buildReportCard(
              context,
              title: 'Customer Ledger',
              subtitle: 'Wallet & Credit',
              icon: FontAwesomeIcons.wallet,
              color: Colors.purpleAccent,
              locked: !isCeo,
              onTap: () {
                if (!isCeo) {
                  AppNotification.showInfo(context, 'CEO access required');
                  return;
                }
                Navigator.push(
                  context,
                  slideLeftRoute(const CustomersScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return Container(
      width: 100,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: AppDropdown<String>(
        value: _selectedPeriod,
        items: _periods
            .map((p) => DropdownMenuItem(
                value: p,
                child: Text(p, style: const TextStyle(fontSize: 12))))
            .toList(),
        onChanged: (v) => setState(() => _selectedPeriod = v ?? 'Day'),
      ),
    );
  }

  Widget _buildReportCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    bool locked = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radiusL),
        child: Container(
          padding: EdgeInsets.all(context.spacingM),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(context.radiusL),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.1),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
            border: Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 24),
                  ),
                  const Spacer(),
                  Text(
                    title,
                    style: context.bodyMedium.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: context.bodySmall.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
              if (locked)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.lock_outline_rounded,
                      size: 14,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.3),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
