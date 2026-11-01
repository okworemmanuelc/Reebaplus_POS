import 'package:reebaplus_pos/features/customers/data/models/customer.dart';

/// Whether [c] matches the search [query]: the name, or the phone, ignoring
/// spaces and symbols in the phone. One rule for every customer search (#648).
/// An empty query matches everyone; a customer with no phone never throws.
bool customerMatchesQuery(Customer c, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final phone = (c.phone ?? '').toLowerCase();
  final qDigits = q.replaceAll(RegExp(r'\D'), '');
  return c.name.toLowerCase().contains(q) ||
      phone.contains(q) ||
      (qDigits.isNotEmpty &&
          phone.replaceAll(RegExp(r'\D'), '').contains(qDigits));
}

/// The Customers list as shown (#648): registered customers only (no
/// walk-in), filtered by [query], customers who owe (`balance < 0`) first and
/// biggest debt first (ties by name), then everyone else in the order given
/// (the existing name order). [balancesKobo] maps customer id to balance.
List<Customer> customerListView(
  Iterable<Customer> customers,
  Map<String, int> balancesKobo,
  String query,
) {
  int balanceOf(Customer c) => balancesKobo[c.id] ?? 0;
  final matched = [
    for (final c in customers)
      if (!c.isWalkIn && customerMatchesQuery(c, query)) c,
  ];
  final owing =
      [
        for (final c in matched)
          if (balanceOf(c) < 0) c,
      ]..sort((a, b) {
        final byDebt = balanceOf(a).compareTo(balanceOf(b));
        return byDebt != 0
            ? byDebt
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  return [
    ...owing,
    for (final c in matched)
      if (balanceOf(c) >= 0) c,
  ];
}
