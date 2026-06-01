import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';

// Flat display-list item: either a store section header or a row index.
class _DisplayItem {
  final String? storeName;
  final int? rowIndex;
  bool get isHeader => storeName != null;
  const _DisplayItem.header(String name)
    : storeName = name,
      rowIndex = null;
  const _DisplayItem.row(int idx) : storeName = null, rowIndex = idx;
}

class StockCountScreen extends ConsumerStatefulWidget {
  /// If provided, only products in this store are loaded and adjustments
  /// are written to this store. Null means all stores (grouped view).
  final String? storeId;

  const StockCountScreen({super.key, this.storeId});

  @override
  ConsumerState<StockCountScreen> createState() => _StockCountScreenState();
}

class _StockCountScreenState extends ConsumerState<StockCountScreen> {
  List<ProductStockWithStore> _items = [];
  final List<TextEditingController> _controllers = [];
  bool _loading = true;
  bool _saving = false;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;
  Color get _card => Theme.of(context).cardColor;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadProducts() async {
    final items = await ref.read(databaseProvider).inventoryDao.getProductsStockPerStore(
      storeId: widget.storeId,
    );
    if (!mounted) return;
    setState(() {
      _items = items;
      _controllers.clear();
      for (final item in items) {
        _controllers.add(
          TextEditingController(text: item.totalStock.toString()),
        );
      }
      _loading = false;
    });
  }

  int _diff(int index) {
    final actual = int.tryParse(_controllers[index].text) ?? 0;
    return actual - _items[index].totalStock;
  }

  Future<void> _saveCount() async {
    setState(() => _saving = true);

    final db = ref.read(databaseProvider);
    final logService = ref.read(activityLogProvider);

    int adjustedCount = 0;
    for (int i = 0; i < _items.length; i++) {
      final diff = _diff(i);
      if (diff == 0) continue;

      final item = _items[i];
      await db.inventoryDao.adjustStock(
        item.product.id,
        item.storeId,
        diff,
        'Daily stock count adjustment',
        null,
      );

      final sign = diff > 0 ? '+' : '';
      await logService.logAction(
        'stock_count',
        'Stock count: ${item.product.name} adjusted by $sign$diff '
            '(system: ${item.totalStock}, actual: ${item.totalStock + diff})',
        productId: item.product.id,
      );

      adjustedCount++;
    }

    if (!mounted) return;
    setState(() => _saving = false);

    if (adjustedCount == 0) {
      AppNotification.showSuccess(context, 'No changes — all counts matched.');
    } else {
      AppNotification.showSuccess(
        context,
        '$adjustedCount product${adjustedCount == 1 ? '' : 's'} adjusted.',
      );
    }

    Navigator.pop(context);
  }

  // ── History ────────────────────────────────────────────────────────────────

  Future<void> _viewHistory(BuildContext context) async {
    final logs = await ref.read(databaseProvider).activityLogDao.getStockCountLogs();

    // Group by calendar date (YYYY-MM-DD key for easy sorting)
    final Map<String, List<ActivityLogData>> grouped = {};
    for (final log in logs) {
      final t = log.createdAt;
      final key =
          '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      grouped.putIfAbsent(key, () => []).add(log);
    }
    final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (ctx, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Handle
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(12)),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
                child: Row(
                  children: [
                    Icon(
                      FontAwesomeIcons.clockRotateLeft,
                      size: context.getRSize(16),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    SizedBox(width: context.getRSize(10)),
                    Text(
                      'Count History',
                      style: TextStyle(
                        color: _text,
                        fontSize: context.getRFontSize(18),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.getRSize(8)),
              Divider(color: _border, height: 1),
              if (dates.isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          FontAwesomeIcons.clockRotateLeft,
                          size: context.getRSize(36),
                          color: _border,
                        ),
                        SizedBox(height: context.getRSize(12)),
                        Text(
                          'No history yet',
                          style: TextStyle(
                            color: _subtext,
                            fontSize: context.getRFontSize(15),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.separated(
                    controller: scrollCtrl,
                    padding: EdgeInsets.fromLTRB(
                      0,
                      context.getRSize(8),
                      0,
                      context.getRSize(8) + context.deviceBottomInset,
                    ),
                    itemCount: dates.length,
                    separatorBuilder: (_, __) => Divider(
                      color: _border,
                      height: 1,
                      indent: context.getRSize(20),
                    ),
                    itemBuilder: (ctx, i) {
                      final dateKey = dates[i];
                      final dayLogs = grouped[dateKey]!;
                      final date = DateTime.parse(dateKey);
                      final label = _formatDate(date);

                      return ListTile(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(20),
                          vertical: context.getRSize(4),
                        ),
                        leading: Container(
                          padding: EdgeInsets.all(context.getRSize(10)),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            FontAwesomeIcons.clipboardCheck,
                            size: context.getRSize(14),
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        title: Text(
                          label,
                          style: TextStyle(
                            color: _text,
                            fontWeight: FontWeight.w700,
                            fontSize: context.getRFontSize(14),
                          ),
                        ),
                        subtitle: Text(
                          '${dayLogs.length} adjustment${dayLogs.length == 1 ? '' : 's'}',
                          style: TextStyle(
                            color: _subtext,
                            fontSize: context.getRFontSize(12),
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: _subtext,
                          size: context.getRSize(20),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showDayDetail(context, label, dayLogs);
                        },
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

  void _showDayDetail(
    BuildContext context,
    String dateLabel,
    List<ActivityLogData> logs,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (ctx, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Handle
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(12)),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dateLabel,
                            style: TextStyle(
                              color: _text,
                              fontSize: context.getRFontSize(18),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'Stock count adjustments',
                            style: TextStyle(
                              color: _subtext,
                              fontSize: context.getRFontSize(12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.getRSize(10),
                        vertical: context.getRSize(4),
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${logs.length} item${logs.length == 1 ? '' : 's'}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: context.getRFontSize(12),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.getRSize(8)),
              Divider(color: _border, height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollCtrl,
                  padding: EdgeInsets.fromLTRB(
                    context.getRSize(16),
                    context.getRSize(12),
                    context.getRSize(16),
                    context.getRSize(12) + context.deviceBottomInset,
                  ),
                  itemCount: logs.length,
                  separatorBuilder: (_, __) =>
                      SizedBox(height: context.getRSize(8)),
                  itemBuilder: (ctx, i) {
                    final log = logs[i];
                    // Detect positive/negative adjustment from description
                    final isPositive = log.description.contains(
                      'adjusted by +',
                    );
                    final isNegative = log.description.contains(
                      'adjusted by -',
                    );
                    final accentColor = isPositive
                        ? success
                        : isNegative
                        ? danger
                        : _subtext;

                    return Container(
                      padding: EdgeInsets.all(context.getRSize(12)),
                      decoration: BoxDecoration(
                        color: _card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            margin: EdgeInsets.only(
                              top: context.getRSize(2),
                              right: context.getRSize(10),
                            ),
                            width: context.getRSize(8),
                            height: context.getRSize(8),
                            decoration: BoxDecoration(
                              color: accentColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  log.description,
                                  style: TextStyle(
                                    color: _text,
                                    fontSize: context.getRFontSize(13),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                SizedBox(height: context.getRSize(4)),
                                Text(
                                  _formatTime(log.createdAt),
                                  style: TextStyle(
                                    color: _subtext,
                                    fontSize: context.getRFontSize(11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
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

  String _formatDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _surface,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Daily Stock Count',
                style: TextStyle(
                  color: _text,
                  fontSize: context.getRFontSize(16),
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (widget.storeId != null)
                Text(
                  'Store #${widget.storeId}',
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(11),
                  ),
                ),
            ],
          ),
          actions: [
            IconButton(
              icon: Icon(
                FontAwesomeIcons.clockRotateLeft,
                color: _text,
                size: context.getRSize(16),
              ),
              tooltip: 'View History',
              onPressed: () => _viewHistory(context),
            ),
            if (!_loading && _saving)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      FontAwesomeIcons.boxOpen,
                      size: context.getRSize(48),
                      color: _subtext.withValues(alpha: 0.4),
                    ),
                    SizedBox(height: context.getRSize(16)),
                    Text(
                      'No products found',
                      style: TextStyle(
                        color: _subtext,
                        fontSize: context.getRFontSize(16),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              )
            : _buildTable(context),
        floatingActionButton: _loading || _saving || _items.isEmpty
            ? null
            : AppFAB(
                heroTag: 'save_count_fab',
                onPressed: _saveCount,
                icon: FontAwesomeIcons.floppyDisk,
                label: 'Save Count',
              ),
    );
  }

  Widget _buildTable(BuildContext context) {
    // Build flat display list: store headers interleaved with row indices
    final displayItems = <_DisplayItem>[];
    String? lastStore;
    for (int i = 0; i < _items.length; i++) {
      final name = _items[i].storeName;
      if (name != lastStore) {
        displayItems.add(_DisplayItem.header(name));
        lastStore = name;
      }
      displayItems.add(_DisplayItem.row(i));
    }

    return Column(
      children: [
        _buildTableHeader(context),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.only(
              bottom:
                  context.getRSize(24) + context.deviceBottomInset,
            ),
            itemCount: displayItems.length,
            itemBuilder: (_, idx) {
              final di = displayItems[idx];
              return di.isHeader
                  ? _buildStoreHeader(context, di.storeName!)
                  : _buildRow(context, di.rowIndex!);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTableHeader(BuildContext context) {
    final style = TextStyle(
      color: _subtext,
      fontSize: context.getRFontSize(11),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );
    return Container(
      color: _surface,
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(10),
      ),
      child: Row(
        children: [
          Expanded(flex: 5, child: Text('PRODUCT', style: style)),
          SizedBox(
            width: context.getRSize(56),
            child: Text('SYSTEM', style: style, textAlign: TextAlign.center),
          ),
          SizedBox(
            width: context.getRSize(72),
            child: Text('ACTUAL', style: style, textAlign: TextAlign.center),
          ),
          SizedBox(
            width: context.getRSize(56),
            child: Text('DIFF', style: style, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  Widget _buildStoreHeader(BuildContext context, String name) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(14),
        context.getRSize(16),
        context.getRSize(6),
      ),
      color: _bg,
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(context.getRSize(6)),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              FontAwesomeIcons.store,
              size: context.getRSize(11),
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            name,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: context.getRFontSize(12),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, int i) {
    final item = _items[i];
    final systemStock = item.totalStock;

    return StatefulBuilder(
      builder: (context, setRowState) {
        final diff = _diff(i);
        final diffColor = diff > 0
            ? success
            : diff < 0
            ? danger
            : _subtext;
        final diffLabel = diff == 0 ? '—' : (diff > 0 ? '+$diff' : '$diff');

        return Container(
          margin: EdgeInsets.symmetric(
            horizontal: context.getRSize(16),
            vertical: context.getRSize(4),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(12),
            vertical: context.getRSize(10),
          ),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: diff != 0 ? diffColor.withValues(alpha: 0.4) : _border,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Text(
                  item.product.name,
                  style: TextStyle(
                    color: _text,
                    fontSize: context.getRFontSize(13),
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: context.getRSize(56),
                child: Text(
                  '$systemStock',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(13),
                  ),
                ),
              ),
              SizedBox(
                width: context.getRSize(72),
                child: AppInput(
                  controller: _controllers[i],
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setRowState(() {}),
                  textAlign: TextAlign.center,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(6),
                    vertical: context.getRSize(8),
                  ),
                  fillColor: _surface,
                ),
              ),
              SizedBox(
                width: context.getRSize(56),
                child: Text(
                  diffLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: diffColor,
                    fontSize: context.getRFontSize(13),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
