/// A geographic choice, independent of any store, shopper, or address record.
/// A null [lga] means the whole state, available only to callers allowing it.
class AreaSelection {
  const AreaSelection({required this.country, required this.state, this.lga});

  final String country;
  final String state;
  final String? lga;

  bool get isWholeState => lga == null;
}
