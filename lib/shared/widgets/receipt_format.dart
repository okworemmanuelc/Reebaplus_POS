/// Pure helpers shared by the phone [ReceiptWidget] and the paper receipt.
class ReceiptFormat {
  ReceiptFormat._();

  /// Quantity with no decimals unless it is a fraction.
  static String qty(double q) => q == q.roundToDouble()
      ? q.toStringAsFixed(0)
      : q.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');

  static double num(dynamic v) =>
      v is double ? v : (v is int ? v.toDouble() : double.tryParse('$v') ?? 0.0);

  /// manufacturerId → crates taken on this sale (bottle lines that track empties).
  static Map<String, double> emptiesByManufacturer(
    List<Map<String, dynamic>> cart,
  ) {
    final out = <String, double>{};
    for (final item in cart) {
      final unit = (item['unit'] as String?)?.toLowerCase();
      final track = (item['trackEmpties'] as bool?) ?? false;
      if (unit == 'bottle' && track) {
        final mid = item['manufacturerId'];
        if (mid is String) out[mid] = (out[mid] ?? 0) + num(item['qty']);
      }
    }
    return out;
  }

  static bool isWalkIn(String? name) {
    final n = name?.trim() ?? '';
    return n.isEmpty || n.toLowerCase() == 'walk-in customer';
  }

  /// "31/10/2026 4:52 PM"
  static String paperDate(DateTime dt) {
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '$h12:${dt.minute.toString().padLeft(2, '0')} $ampm';
  }
}
