// InventoryLog model
// TODO: define InventoryLog class
class InventoryLog {
  final DateTime timestamp;
  final String user;
  final String itemId;
  final String itemName;
  final String
  action; // 'restock', 'adjustment', 'crate_update', 'new_supplier'
  final double previousValue;
  final double newValue;
  final String? note;
  final String? storeId;

  InventoryLog({
    required this.timestamp,
    required this.user,
    required this.itemId,
    required this.itemName,
    required this.action,
    required this.previousValue,
    required this.newValue,
    this.note,
    this.storeId,
  });
}
