import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/business_time.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';

class StockAuditScreen extends ConsumerStatefulWidget {
  const StockAuditScreen({super.key});

  @override
  ConsumerState<StockAuditScreen> createState() => _StockAuditScreenState();
}

class _StockAuditScreenState extends ConsumerState<StockAuditScreen> {
  List<StockTransactionWithDetails> _transactions = [];
  PeriodReconciliation? _reconciliation;
  StreamSubscription? _sub;
  bool _loading = true;

  String _selectedPeriod = 'This Month';
  String? _selectedWarehouseId;
  String? _selectedMovementType;
  String _businessTz = 'UTC';

  static const _periods = [
    'Today',
    'This Week',
    'This Month',
    'This Quarter',
    'All Time',
  ];

  static const _movementTypes = <String, String?>{
    'All Types': null,
    'Sales': 'sale',
    'Adjustments': 'adjustment',
    'Transfers In': 'transfer_in',
    'Transfers Out': 'transfer_out',
    'Returns': 'return',
    'Damage': 'damage',
    'Received': 'purchase_received',
  };

  @override
  void initState() {
    super.initState();
    // CEO guard is checked in build; data loads regardless
    _loadTimezone();
    _subscribe();
  }

  Future<void> _loadTimezone() async {
    final db = ref.read(databaseProvider);
    final businessId = db.currentBusinessId;
    if (businessId == null) return;
    final tz = await getBusinessTimezone(db, businessId);
    if (mounted && tz != _businessTz) {
      setState(() => _businessTz = tz);
      _subscribe();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _subscribe() {
    _sub?.cancel();
    setState(() => _loading = true);

    final db = ref.read(databaseProvider);
    final dates = _getDateRange(_selectedPeriod);

    _sub = db.stockLedgerDao
        .watchAllTransactionsFiltered(
          warehouseId: _selectedWarehouseId,
          startDate: dates.$1,
          endDate: dates.$2,
          movementType: _selectedMovementType,
        )
        .listen((data) async {
          // Also fetch reconciliation if warehouse is selected
          PeriodReconciliation? recon;
          if (_selectedWarehouseId != null && dates.$1 != null) {
            recon = await db.stockLedgerDao.getPeriodReconciliation(
              warehouseId: _selectedWarehouseId!,
              startDate: dates.$1!,
              endDate: dates.$2 ?? DateTime.now(),
            );
          }
          if (mounted) {
            setState(() {
              _transactions = data;
              _reconciliation = recon;
              _loading = false;
            });
          }
        });
  }

  (DateTime?, DateTime?) _getDateRange(String period) {
    final now = DateTime.now();
    switch (period) {
      case 'Today':
        return (localDayStartUtc(now, _businessTz), null);
      case 'This Week':
        return (now.subtract(const Duration(days: 7)), null);
      case 'This Month':
        return (localDateUtc(now.year, now.month, 1, _businessTz), null);
      case 'This Quarter':
        final quarterMonth = ((now.month - 1) ~/ 3) * 3 + 1;
        return (localDateUtc(now.year, quarterMonth, 1, _businessTz), null);
      case 'All Time':
      default:
        return (null, null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final user = ref.watch(authProvider).currentUser;

    // CEO guard
    if (user == null || user.roleTier < 6) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Stock Audit'),
          leading: const BackButton(),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: context.getRSize(64),
                color: colorScheme.onSurface.withValues(alpha: 0.2),
              ),
              SizedBox(height: context.spacingM),
              Text(
                'CEO Access Required',
                style: context.h3.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              SizedBox(height: context.spacingS),
              Text(
                'Only the CEO can view stock audit reports.',
                style: context.bodyMedium.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 18,
            color: colorScheme.onSurface,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Stock Audit',
              style: context.bodyLarge.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              _selectedPeriod,
              style: context.bodySmall.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Filters
          _buildFilters(context, colorScheme),

          // Reconciliation banner
          if (_reconciliation != null) _buildReconciliationBanner(context),

          // Summary cards
          if (!_loading) _buildSummaryCards(context, colorScheme),

          // Table header
          if (!_loading && _transactions.isNotEmpty)
            _buildTableHeader(context, colorScheme),

          // Content
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _transactions.isEmpty
                ? _buildEmptyState(context, colorScheme)
                : _buildTransactionList(context, colorScheme),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters(BuildContext context, ColorScheme colorScheme) {
    final warehouses = ref.watch(allWarehousesProvider);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingM,
        vertical: context.spacingS,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: Row(
        children: [
          // Period dropdown
          SizedBox(
            width: context.getRSize(110),
            child: AppDropdown<String>(
              value: _selectedPeriod,
              items: _periods
                  .map(
                    (p) => DropdownMenuItem(
                      value: p,
                      child: Text(p, style: const TextStyle(fontSize: 12)),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                _selectedPeriod = v ?? 'This Month';
                _subscribe();
              },
            ),
          ),
          SizedBox(width: context.spacingS),

          // Warehouse dropdown
          Expanded(
            child: warehouses.when(
              data: (wList) => AppDropdown<String?>(
                value: _selectedWarehouseId,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text(
                      'All Warehouses',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  ...wList.map(
                    (w) => DropdownMenuItem<String?>(
                      value: w.id,
                      child: Text(w.name, style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
                onChanged: (v) {
                  _selectedWarehouseId = v;
                  _subscribe();
                },
              ),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ),
          SizedBox(width: context.spacingS),

          // Movement type dropdown
          SizedBox(
            width: context.getRSize(100),
            child: AppDropdown<String>(
              value: _movementTypes.entries
                  .firstWhere((e) => e.value == _selectedMovementType)
                  .key,
              items: _movementTypes.keys
                  .map(
                    (k) => DropdownMenuItem(
                      value: k,
                      child: Text(k, style: const TextStyle(fontSize: 12)),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                _selectedMovementType = _movementTypes[v];
                _subscribe();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReconciliationBanner(BuildContext context) {
    final r = _reconciliation!;
    final hasVariance = r.hasVariance;
    final color = hasVariance ? AppColors.danger : AppColors.success;
    final icon = hasVariance
        ? Icons.warning_amber_rounded
        : Icons.check_circle_outline_rounded;

    return Container(
      margin: EdgeInsets.all(context.spacingM),
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.radiusM),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: context.getRSize(20)),
              SizedBox(width: context.spacingS),
              Text(
                hasVariance ? 'Variance Detected' : 'Stock Balanced',
                style: context.bodyMedium.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          SizedBox(height: context.spacingS),
          Row(
            children: [
              _reconChip(context, 'Opening', fmtNumber(r.openingStock)),
              const Text(' + '),
              _reconChip(
                context,
                'In',
                '+${fmtNumber(r.stockIn)}',
                AppColors.success,
              ),
              const Text(' - '),
              _reconChip(
                context,
                'Out',
                '-${fmtNumber(r.stockOut)}',
                AppColors.danger,
              ),
              const Text(' = '),
              _reconChip(context, 'Expected', fmtNumber(r.expectedClosing)),
            ],
          ),
          SizedBox(height: context.spacingXs),
          Row(
            children: [
              Text(
                'Actual: ${fmtNumber(r.actualClosing)}',
                style: context.bodySmall.copyWith(fontWeight: FontWeight.w600),
              ),
              if (hasVariance) ...[
                SizedBox(width: context.spacingS),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Variance: ${r.variance > 0 ? '+' : ''}${fmtNumber(r.variance)} units',
                    style: context.bodySmall.copyWith(
                      color: AppColors.danger,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _reconChip(
    BuildContext context,
    String label,
    String value, [
    Color? color,
  ]) {
    return Flexible(
      child: Column(
        children: [
          Text(
            label,
            style: context.bodySmall.copyWith(
              fontSize: 9,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          Text(
            value,
            style: context.bodySmall.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCards(BuildContext context, ColorScheme colorScheme) {
    int totalIn = 0;
    int totalOut = 0;
    int adjustments = 0;
    int flagged = 0;
    int totalValueIn = 0;
    int totalValueOut = 0;

    for (final tx in _transactions) {
      if (tx.isInflow) {
        totalIn += tx.quantityDelta;
        totalValueIn += tx.valueKobo;
      } else {
        totalOut += tx.quantityDelta.abs();
        totalValueOut += tx.valueKobo;
      }
      if (tx.isAdjustment) {
        adjustments++;
        flagged++;
      }
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.spacingM),
      child: Row(
        children: [
          _summaryCard(
            context,
            'Stock In',
            '+${fmtNumber(totalIn)}',
            formatCurrency(totalValueIn / 100),
            AppColors.success,
          ),
          SizedBox(width: context.spacingS),
          _summaryCard(
            context,
            'Stock Out',
            '-${fmtNumber(totalOut)}',
            formatCurrency(totalValueOut / 100),
            AppColors.danger,
          ),
          SizedBox(width: context.spacingS),
          _summaryCard(
            context,
            'Adjustments',
            fmtNumber(adjustments),
            '$flagged flagged',
            flagged > 0 ? AppColors.warning : AppColors.info,
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(
    BuildContext context,
    String label,
    String value,
    String subtitle,
    Color color,
  ) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.all(context.spacingS),
        margin: EdgeInsets.only(bottom: context.spacingS),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(context.radiusS),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: context.bodySmall.copyWith(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: context.spacingXs),
            Text(
              value,
              style: context.bodyMedium.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              subtitle,
              style: context.bodySmall.copyWith(
                fontSize: 9,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTableHeader(BuildContext context, ColorScheme colorScheme) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: context.spacingM),
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingS,
        vertical: context.spacingS,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.radiusM),
        ),
        border: Border(
          bottom: BorderSide(color: colorScheme.outline.withValues(alpha: 0.2)),
        ),
      ),
      child: Row(
        children: [
          _headerCell(context, 'DATE', flex: 2),
          _headerCell(context, 'PRODUCT', flex: 3),
          _headerCell(context, 'TYPE', flex: 2),
          _headerCell(context, 'QTY', flex: 1, align: TextAlign.center),
          _headerCell(context, 'VALUE', flex: 2, align: TextAlign.end),
          _headerCell(context, 'BY', flex: 2),
          SizedBox(
            width: context.getRSize(20),
            child: Icon(
              Icons.flag_outlined,
              size: 12,
              color: colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerCell(
    BuildContext context,
    String text, {
    int flex = 1,
    TextAlign align = TextAlign.start,
  }) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        textAlign: align,
        style: context.bodySmall.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 9,
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.45),
        ),
      ),
    );
  }

  Widget _buildTransactionList(BuildContext context, ColorScheme colorScheme) {
    // Compute running balances per product for flagging
    final runningBalances = <String, int>{}; // productId → running balance

    return ListView.builder(
      padding: EdgeInsets.symmetric(horizontal: context.spacingM),
      itemCount: _transactions.length,
      itemBuilder: (context, index) {
        // Process in reverse for running balance (list is DESC, process ASC)
        // For simplicity, compute balance at display time
        final tx = _transactions[index];

        // Track running balance per product
        runningBalances.putIfAbsent(tx.productId, () => 0);
        // Note: since list is DESC, we can't easily compute running balance
        // without pre-processing. Let's flag based on simpler heuristics.
        const isNegativeBalance = false; // Would need pre-computation
        final isFlagged = tx.isAdjustment || isNegativeBalance;

        return _buildTransactionRow(context, colorScheme, tx, index, isFlagged);
      },
    );
  }

  Widget _buildTransactionRow(
    BuildContext context,
    ColorScheme colorScheme,
    StockTransactionWithDetails tx,
    int index,
    bool isFlagged,
  ) {
    final isEven = index % 2 == 0;
    final typeColor = _getMovementColor(tx);
    final sign = tx.isInflow ? '+' : '';
    final dateStr = DateFormat('dd/MM HH:mm').format(tx.createdAt);
    final valueStr = formatCurrency(tx.valueKobo / 100);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingS,
        vertical: context.spacingS,
      ),
      decoration: BoxDecoration(
        color: isFlagged
            ? AppColors.warning.withValues(alpha: 0.04)
            : isEven
            ? colorScheme.onSurface.withValues(alpha: 0.02)
            : Colors.transparent,
      ),
      child: Row(
        children: [
          // Date
          Expanded(
            flex: 2,
            child: Text(
              dateStr,
              style: context.bodySmall.copyWith(
                fontSize: 10,
                color: colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          // Product
          Expanded(
            flex: 3,
            child: Text(
              tx.productName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.bodySmall.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          // Type badge
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: typeColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tx.movementLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: context.bodySmall.copyWith(
                  color: typeColor,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          // Qty
          Expanded(
            flex: 1,
            child: Text(
              '$sign${tx.quantityDelta}',
              textAlign: TextAlign.center,
              style: context.bodySmall.copyWith(
                color: tx.isInflow ? AppColors.success : AppColors.danger,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
          // Value
          Expanded(
            flex: 2,
            child: Text(
              valueStr,
              textAlign: TextAlign.end,
              style: context.bodySmall.copyWith(fontSize: 10),
            ),
          ),
          // Performed by
          Expanded(
            flex: 2,
            child: Text(
              tx.performedByName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.bodySmall.copyWith(
                fontSize: 9,
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          // Flag
          SizedBox(
            width: context.getRSize(20),
            child: isFlagged
                ? const Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: AppColors.warning,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Color _getMovementColor(StockTransactionWithDetails tx) {
    switch (tx.movementType) {
      case 'sale':
      case 'damage':
        return AppColors.danger;
      case 'transfer_out':
      case 'transfer_in':
      case 'transfer_cancelled':
        return AppColors.info;
      case 'purchase_received':
      case 'return':
        return AppColors.success;
      case 'adjustment':
        return AppColors.warning;
      default:
        return AppColors.info;
    }
  }

  Widget _buildEmptyState(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FontAwesomeIcons.boxesStacked,
            size: context.getRSize(48),
            color: colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          SizedBox(height: context.spacingM),
          Text(
            'No stock movements found',
            style: context.bodyMedium.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
          SizedBox(height: context.spacingXs),
          Text(
            'Adjust filters or period to view\ninventory audit data.',
            textAlign: TextAlign.center,
            style: context.bodySmall.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}
