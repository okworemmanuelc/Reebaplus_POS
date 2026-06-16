import 'package:reebaplus_pos/core/database/app_database.dart';

class ReorderAlert {
  final String productId;
  final String productName;
  final int currentStock;
  final double rop;

  ReorderAlert({
    required this.productId,
    required this.productName,
    required this.currentStock,
    required this.rop,
  });
}

class ReorderAlertService {
  final StockLedgerDao _stockLedgerDao;

  ReorderAlertService(this._stockLedgerDao);

  /// Checks for products below ROP and returns a list of alerts.
  Future<List<ReorderAlert>> checkAndNotify(String locationId) async {
    final productsBelowROP = await _stockLedgerDao.getProductsBelowROP(
      locationId,
    );

    return productsBelowROP
        .map(
          (p) => ReorderAlert(
            productId: p.productId,
            productName: p.productName,
            currentStock: p.currentStock,
            rop: p.rop,
          ),
        )
        .toList();
  }
}
