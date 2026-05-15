import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_constants.dart';

class WarehouseDetailsScreen extends ConsumerStatefulWidget {
  final WarehouseData warehouse;

  const WarehouseDetailsScreen({super.key, required this.warehouse});

  @override
  ConsumerState<WarehouseDetailsScreen> createState() =>
      _WarehouseDetailsScreenState();
}

class _WarehouseDetailsScreenState
    extends ConsumerState<WarehouseDetailsScreen> {
  WarehouseData? _liveWarehouse;
  List<ProductDataWithStock> _inventory = [];
  List<UserData> _staff = [];
  List<CustomerData> _customers = [];

  StreamSubscription<WarehouseData?>? _warehouseSub;
  StreamSubscription<List<ProductDataWithStock>>? _inventorySub;
  StreamSubscription<List<UserData>>? _staffSub;
  StreamSubscription<List<CustomerData>>? _customersSub;

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  WarehouseData get _warehouse => _liveWarehouse ?? widget.warehouse;

  @override
  void initState() {
    super.initState();
    final id = widget.warehouse.id;
    final db = ref.read(databaseProvider);

    _warehouseSub = db.warehousesDao.watchWarehouse(id).listen((w) {
      if (mounted && w != null) setState(() => _liveWarehouse = w);
    });
    _inventorySub = db.inventoryDao
        .watchProductDatasWithStockByWarehouse(id)
        .listen((list) {
          if (mounted) setState(() => _inventory = list);
        });
    _staffSub = db.warehousesDao.watchStaffByWarehouse(id).listen((list) {
      if (mounted) setState(() => _staff = list);
    });
    _customersSub = db.customersDao.watchCustomersByWarehouse(id).listen((
      list,
    ) {
      if (mounted) setState(() => _customers = list);
    });
  }

  @override
  void dispose() {
    _warehouseSub?.cancel();
    _inventorySub?.cancel();
    _staffSub?.cancel();
    _customersSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalStock = _inventory.fold<int>(0, (sum, p) => sum + p.totalStock);
    final totalValue = _inventory.fold<double>(
      0.0,
      (sum, p) => sum + (p.totalStock * (p.product.sellingPriceKobo / 100.0)),
    );
    final activeProducts = _inventory.where((p) => p.totalStock > 0).length;
    final lowStock = _inventory
        .where(
          (p) =>
              p.totalStock > 0 && p.totalStock <= p.product.lowStockThreshold,
        )
        .length;
    final managers = _staff.where((u) => u.roleTier >= 5).length;
    final riders = _staff
        .where(
          (u) =>
              u.role.toLowerCase().contains('rider') ||
              u.role.toLowerCase().contains('driver'),
        )
        .length;
    final regularStaff = _staff.length - managers;
    final customersCount = _customers.length;
    final currentUser = ref.watch(authProvider).currentUser;

    return SharedScaffold(
      activeRoute: 'warehouse',
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: _text, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: AppBarHeader(
          icon: FontAwesomeIcons.warehouse,
          title: _warehouse.name,
          subtitle: _warehouse.location ?? 'Main Storage',
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 600;
          return ListView(
            padding: EdgeInsets.all(rSize(context, 16)),
            children: [
              _buildMetricOverview(totalStock, totalValue),
              SizedBox(height: rSize(context, 20)),
              _buildStatsGrid(
                isWide,
                managers,
                regularStaff,
                riders,
                activeProducts,
                lowStock,
                customersCount,
              ),
              SizedBox(height: rSize(context, 24)),
              _buildInventoryList(),
              SizedBox(height: rSize(context, 16)),
              _buildStaffList(currentUser),
              SizedBox(height: rSize(context, 16)),
              _buildQuickActions(isWide),
              SizedBox(height: rSize(context, 100)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMetricOverview(int totalStock, double totalValue) {
    return Container(
      padding: EdgeInsets.all(rSize(context, 20)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.secondary,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Warehouse Value',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: rFontSize(context, 14),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: rSize(context, 4)),
                Text(
                  formatCurrency(totalValue),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: rFontSize(context, 28),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: rSize(context, 16),
              vertical: rSize(context, 8),
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text(
                  totalStock.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                Text(
                  'Total Units',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsGrid(
    bool isWide,
    int managers,
    int regularStaff,
    int riders,
    int activeProducts,
    int lowStock,
    int customersCount,
  ) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: isWide ? 4 : 2,
      mainAxisSpacing: rSize(context, 12),
      crossAxisSpacing: rSize(context, 12),
      childAspectRatio: 1.1,
      children: [
        _buildStatCard(
          'Managers',
          managers.toString(),
          FontAwesomeIcons.userTie,
          const Color(0xFFA855F7),
        ),
        _buildStatCard(
          'Staff',
          regularStaff.toString(),
          FontAwesomeIcons.userGroup,
          Theme.of(context).colorScheme.primary,
        ),
        _buildStatCard(
          'Riders',
          riders.toString(),
          FontAwesomeIcons.motorcycle,
          AppColors.warning,
        ),
        _buildStatCard(
          'Products',
          activeProducts.toString(),
          FontAwesomeIcons.boxesStacked,
          AppColors.success,
        ),
        _buildStatCard(
          'Low Stock',
          lowStock.toString(),
          FontAwesomeIcons.triangleExclamation,
          AppColors.danger,
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final nav = ref.read(navigationProvider);
            nav.customersInitialWarehouseId.value = widget.warehouse.id;
            Navigator.of(context).pop();
            nav.setIndex(4);
          },
          child: _buildStatCard(
            'Customers',
            customersCount.toString(),
            FontAwesomeIcons.users,
            const Color(0xFF06B6D4),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: EdgeInsets.all(rSize(context, 16)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: EdgeInsets.all(rSize(context, 8)),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: rSize(context, 16)),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: rFontSize(context, 20),
                  fontWeight: FontWeight.w900,
                  color: _text,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: rFontSize(context, 12),
                  color: _subtext,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Inventory List ──────────────────────────────────────────────────────────
  Widget _buildInventoryList() {
    final stocked = _inventory.where((p) => p.totalStock > 0).toList()
      ..sort((a, b) => b.totalStock.compareTo(a.totalStock));

    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: EdgeInsets.symmetric(
            horizontal: rSize(context, 16),
            vertical: 0,
          ),
          leading: Container(
            padding: EdgeInsets.all(rSize(context, 8)),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              FontAwesomeIcons.boxesStacked,
              color: AppColors.success,
              size: rSize(context, 14),
            ),
          ),
          title: Text(
            'Inventory',
            style: TextStyle(
              fontSize: rFontSize(context, 15),
              fontWeight: FontWeight.bold,
              color: _text,
            ),
          ),
          subtitle: Text(
            '${stocked.length} product${stocked.length == 1 ? '' : 's'} in stock',
            style: TextStyle(fontSize: rFontSize(context, 12), color: _subtext),
          ),
          children: stocked.isEmpty
              ? [
                  Padding(
                    padding: EdgeInsets.all(rSize(context, 20)),
                    child: Text(
                      'No stock in this warehouse yet.',
                      style: TextStyle(
                        color: _subtext,
                        fontSize: rFontSize(context, 13),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ]
              : stocked.map((item) {
                  final isLow =
                      item.totalStock <= item.product.lowStockThreshold;
                  return Container(
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: _border)),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: rSize(context, 16),
                        vertical: rSize(context, 12),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.product.name,
                                  style: TextStyle(
                                    fontSize: rFontSize(context, 14),
                                    fontWeight: FontWeight.w600,
                                    color: _text,
                                  ),
                                ),
                                if (item.product.unit.isNotEmpty) ...[
                                  SizedBox(height: rSize(context, 2)),
                                  Text(
                                    item.product.unit,
                                    style: TextStyle(
                                      fontSize: rFontSize(context, 11),
                                      color: _subtext,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: rSize(context, 10),
                              vertical: rSize(context, 4),
                            ),
                            decoration: BoxDecoration(
                              color: isLow
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.error.withValues(alpha: 0.1)
                                  : AppColors.success.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${item.totalStock} units',
                              style: TextStyle(
                                fontSize: rFontSize(context, 12),
                                fontWeight: FontWeight.bold,
                                color: isLow
                                    ? AppColors.danger
                                    : AppColors.success,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
        ),
      ),
    );
  }

  // ── Staff List ──────────────────────────────────────────────────────────────
  Widget _buildStaffList(UserData? currentUser) {
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: EdgeInsets.symmetric(
            horizontal: rSize(context, 16),
            vertical: 0,
          ),
          leading: Container(
            padding: EdgeInsets.all(rSize(context, 8)),
            decoration: BoxDecoration(
              color: const Color(0xFFA855F7).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              FontAwesomeIcons.userGroup,
              color: const Color(0xFFA855F7),
              size: rSize(context, 14),
            ),
          ),
          title: Text(
            'Assigned Staff',
            style: TextStyle(
              fontSize: rFontSize(context, 15),
              fontWeight: FontWeight.bold,
              color: _text,
            ),
          ),
          subtitle: Text(
            '${_staff.length} personnel',
            style: TextStyle(fontSize: rFontSize(context, 12), color: _subtext),
          ),
          children: _staff.isEmpty
              ? [
                  Padding(
                    padding: EdgeInsets.all(rSize(context, 20)),
                    child: Text(
                      'No staff assigned to this warehouse.',
                      style: TextStyle(
                        color: _subtext,
                        fontSize: rFontSize(context, 13),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ]
              : _staff.map((member) {
                  final roleInfo = roleFor(member.role);

                  final roleColor = roleInfo.color;

                  final isDisabled =
                      currentUser != null &&
                      currentUser.roleTier < member.roleTier;

                  return Opacity(
                    opacity: isDisabled ? 0.5 : 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: _border)),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: rSize(context, 16),
                          vertical: rSize(context, 12),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: rSize(context, 18),
                              backgroundColor: roleColor.withValues(
                                alpha: 0.15,
                              ),
                              child: Text(
                                member.name.isNotEmpty
                                    ? member.name[0].toUpperCase()
                                    : '?',
                                style: TextStyle(
                                  fontSize: rFontSize(context, 14),
                                  fontWeight: FontWeight.bold,
                                  color: roleColor,
                                ),
                              ),
                            ),
                            SizedBox(width: rSize(context, 12)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    member.name,
                                    style: TextStyle(
                                      fontSize: rFontSize(context, 14),
                                      fontWeight: FontWeight.w600,
                                      color: _text,
                                    ),
                                  ),
                                  SizedBox(height: rSize(context, 2)),
                                  Text(
                                    member.role,
                                    style: TextStyle(
                                      fontSize: rFontSize(context, 11),
                                      color: _subtext,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: rSize(context, 8),
                                vertical: rSize(context, 3),
                              ),
                              decoration: BoxDecoration(
                                color: roleColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                roleInfo.label,

                                style: TextStyle(
                                  fontSize: rFontSize(context, 10),
                                  fontWeight: FontWeight.bold,
                                  color: roleColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
        ),
      ),
    );
  }

  // ── Quick Actions ───────────────────────────────────────────────────────────
  Widget _buildQuickActions(bool isWide) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick Actions',
          style: TextStyle(
            fontSize: rFontSize(context, 16),
            fontWeight: FontWeight.bold,
            color: _text,
          ),
        ),
        SizedBox(height: rSize(context, 12)),
        Row(
          children: [
            Expanded(
              child: _actionTile(
                'View Inventory',
                'Check and manage stock',
                FontAwesomeIcons.boxesStacked,
                Theme.of(context).colorScheme.primary,
                () {
                  final nav = ref.read(navigationProvider);
                  nav.selectedWarehouseId.value = widget.warehouse.id
                      .toString();
                  nav.setIndex(2);
                },
              ),
            ),
            SizedBox(width: rSize(context, 12)),
            Expanded(
              child: _actionTile(
                'Manage Staff',
                'View assigned personnel',
                FontAwesomeIcons.usersGear,
                const Color(0xFFA855F7),
                () {
                  Navigator.of(context).pop();
                  ref.read(navigationProvider).setIndex(8);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _actionTile(
    String title,
    String subtitle,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.all(rSize(context, 16)),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(rSize(context, 10)),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: rSize(context, 18)),
            ),
            SizedBox(height: rSize(context, 12)),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: rFontSize(context, 14),
                color: _text,
              ),
            ),
            SizedBox(height: rSize(context, 2)),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: rFontSize(context, 11),
                color: _subtext,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
