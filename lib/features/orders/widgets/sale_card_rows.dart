import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';

// #732 — what the Orders card and the Return and Edit sheets say about goods
// added to a sale by an edit. Pure wording: nothing here decides a quantity.

String _day(DateTime at) => DateFormat('d MMM').format(at);

/// "+2 added 4 Nov at ₦1,200" for the added goods still standing in [goods],
/// null when there are none.
String? addedGoodsNote(ReturnableGoods goods) {
  final parts = [
    for (final l in goods.lines)
      if (l.isAdded && l.standing > 0)
        '+${formatQty(l.standing)} added ${_day(l.addedAt!)} '
            'at ${formatCurrency(l.unitPriceKobo / 100.0)}',
  ];
  return parts.isEmpty ? null : parts.join(', ');
}

/// One row of the Orders card: a sale line with the goods added to its product.
class SaleCardRow {
  SaleCardRow(this.name, this.productKey, this.quantity, this.totalKobo);
  final String name;
  final String? productKey;
  double quantity;
  int totalKobo;

  /// Day added -> units, oldest first.
  final Map<String, double> addedByDay = {};

  String get label {
    final base = '${formatQty(quantity)}× $name';
    if (addedByDay.isEmpty) return base;
    final added = [
      for (final e in addedByDay.entries)
        '+${formatQty(e.value)} added ${e.key}',
    ].join(', ');
    return '$base ($added)';
  }
}

String? _productKey(OrderItemData line) =>
    line.productId == null ? null : '${line.productId}|${line.storeId}';

/// [items] as card rows, with every plus line of [adjustments] joined to the
/// first row of its product or, for a new product, as its own row. The quantity
/// is everything sold; what came back stays on the "Returned" lines.
List<SaleCardRow> saleCardRows(
  List<OrderItemDataWithProductData> items,
  List<SaleAdjustmentLines> adjustments,
) {
  final rows = [
    for (final i in items)
      SaleCardRow(
        i.displayName,
        _productKey(i.item),
        i.item.quantity,
        i.item.totalKobo,
      ),
  ];
  final oldestFirst = adjustments.toList()
    ..sort((a, b) => a.adjustment.createdAt.compareTo(b.adjustment.createdAt));
  for (final a in oldestFirst) {
    for (final l in a.lines) {
      if (l.item.quantity <= 0) continue;
      final key = _productKey(l.item);
      var matches = rows.where((r) => r.productKey == key);
      if (matches.isEmpty) {
        rows.add(SaleCardRow(l.displayName, key, 0, 0));
        matches = [rows.last];
      }
      final row = matches.first;
      row.quantity += l.item.quantity;
      row.totalKobo += l.item.totalKobo;
      final day = _day(a.adjustment.createdAt);
      row.addedByDay[day] = (row.addedByDay[day] ?? 0) + l.item.quantity;
    }
  }
  return rows;
}

/// The "Returned: …" / "Edited: …" line of one adjustment.
String adjustmentSummary(SaleAdjustmentLines a, {required bool showMoney}) {
  final edited = a.lines.any((l) => l.item.quantity > 0);
  final what = [
    for (final l in a.lines)
      edited
          ? '${l.item.quantity > 0 ? '+' : '-'}'
                '${formatQty(l.item.quantity.abs())} × ${l.displayName}'
          : '${formatQty(-l.item.quantity)} × ${l.displayName}',
  ].join(', ');
  final net = a.adjustment.netAmountKobo;
  final money = !showMoney
      ? ''
      : ' · ${edited && net > 0 ? '+' : ''}'
            '${formatCurrency((edited ? net : -net) / 100.0)}';
  return '${edited ? 'Edited' : 'Returned'}: $what$money'
      ' · ${a.adjustment.orderNumber}';
}
