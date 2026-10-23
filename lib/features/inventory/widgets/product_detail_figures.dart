import 'package:reebaplus_pos/core/utils/product_unit.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/product_tile.dart'
    show StockLevel;

// The plain numbers and words behind Product Details (#487 PR 3). Pure Dart —
// no widgets, no database — so each rule has one home and a plain unit test.

/// The muted line under the name: "Nigerian Breweries · Crate of 12 bottles".
///
/// Built from the manufacturer, the unit ([unitLabel]) and the "how many in
/// one" count. Parts that are missing are left out. A Bottle product with no
/// count reads "Bottle Crate"; with one it reads "Crate of 12 bottles". A Pack,
/// Carton or Box with a count reads "Pack of 24 pieces". The count never
/// changes any other unit's words.
String productKindLine({
  String? manufacturer,
  String? unit,
  int? unitsPerPack,
}) {
  final parts = <String>[];
  final mfr = manufacturer?.trim() ?? '';
  if (mfr.isNotEmpty) parts.add(mfr);
  final kind = _kindWords(unit, unitsPerPack);
  if (kind != null && kind.isNotEmpty) parts.add(kind);
  return parts.join(' · ');
}

String? _kindWords(String? unit, int? count) {
  final u = unit?.trim() ?? '';
  if (u.isEmpty) return null;
  final lower = u.toLowerCase();
  final n = (count != null && count > 0) ? count : null;
  if (n != null) {
    if (lower == 'bottle') {
      return 'Crate of $n ${n == 1 ? 'bottle' : 'bottles'}';
    }
    if (lower == 'pack' || lower == 'carton' || lower == 'box') {
      return '$u of $n ${n == 1 ? 'piece' : 'pieces'}';
    }
  }
  return unitLabel(u);
}

/// Profit as a whole percent of the selling price: `(price − cost) / price`,
/// rounded. 0 when there is no price to divide by.
int profitPercentOfPrice(int priceKobo, int costKobo) {
  if (priceKobo <= 0) return 0;
  return ((priceKobo - costKobo) * 100 / priceKobo).round();
}

/// Where a store's (or the whole) stock stands against the alert level —
/// Inventory's rule: out at 0, low from 1 up to and including the alert.
StockLevel stockLevelOf(num quantity, num alertAt) {
  if (quantity <= 0) return StockLevel.out;
  if (quantity <= alertAt) return StockLevel.low;
  return StockLevel.ok;
}

/// The Sales Target card's figures for one month, from the crates [sold] so far
/// this calendar month, the monthly [target] and [now].
class SalesTargetFigures {
  SalesTargetFigures({
    required this.sold,
    required this.target,
    required DateTime now,
  }) : month = _months[now.month - 1],
       daysLeft = DateTime(now.year, now.month + 1, 0).day - now.day;

  final int sold;
  final int target;

  /// The month's full name ("October").
  final String month;

  /// The last day of the month minus today.
  final int daysLeft;

  bool get hasTarget => target > 0;
  bool get reached => hasTarget && sold >= target;

  /// Crates still to sell, never below 0.
  int get remaining => hasTarget ? (target - sold).clamp(0, target) : 0;

  /// The whole percent sold (may pass 100); 0 with no target.
  int get percent => hasTarget ? (sold * 100 / target).round() : 0;

  /// The bar's fill, 0 to 1.
  double get fraction => hasTarget ? (sold / target).clamp(0.0, 1.0) : 0.0;

  /// Crates a day still needed, rounding up and counting today as a selling
  /// day, so [daysLeft] + 1 days.
  int get perDay => remaining == 0 ? 0 : (remaining / (daysLeft + 1)).ceil();

  /// "October, 8 days left" ("1 day left", "Last day" on the 31st).
  String get headline {
    final left = switch (daysLeft) {
      0 => 'last day',
      1 => '1 day left',
      _ => '$daysLeft days left',
    };
    return '$month, $left';
  }

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
}

/// How the expiry pill reads and which tone it takes.
enum ExpiryTone { expired, soon, later }

({String label, ExpiryTone tone}) expiryPillFor(DateTime expiry, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final days = DateTime(
    expiry.year,
    expiry.month,
    expiry.day,
  ).difference(today).inDays;
  if (days < 0) return (label: 'Expired', tone: ExpiryTone.expired);
  if (days == 0) return (label: 'Expires today', tone: ExpiryTone.soon);
  if (days <= 30) return (label: 'Expires in ${days}d', tone: ExpiryTone.soon);
  const mon = [
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
  return (
    label: 'Expires ${expiry.day} ${mon[expiry.month - 1]} ${expiry.year}',
    tone: ExpiryTone.later,
  );
}
