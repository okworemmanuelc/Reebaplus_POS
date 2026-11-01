// #648: the Customers list view: search, debtors first, walk-in skipped.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/customers/data/customer_list_view.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';

Customer _c(String id, String name, {String? phone, bool walkIn = false}) =>
    Customer(
      id: id,
      name: name,
      addressText: '',
      googleMapsLocation: '',
      phone: phone,
      isWalkIn: walkIn,
    );

List<String> _names(List<Customer> l) => [for (final c in l) c.name];

void main() {
  final ada = _c('1', 'Ada', phone: '0803 111 2222');
  final bola = _c('2', 'Bola');
  final chidi = _c('3', 'Chidi', phone: '+234 805-333-4444');
  final dayo = _c('4', 'Dayo');
  final eze = _c('5', 'Eze');
  final all = [ada, bola, chidi, dayo, eze];

  group('customerListView order', () {
    test('debtors first, biggest debt first, ties by name, rest in order', () {
      final out = customerListView(all, {
        '1': 500, // credit
        '3': -2000,
        '4': -9000,
        '5': -2000,
      }, '');
      expect(_names(out), ['Dayo', 'Chidi', 'Eze', 'Ada', 'Bola']);
    });

    test('nobody owes: the given name order is kept', () {
      expect(_names(customerListView(all, const {}, '')), [
        'Ada',
        'Bola',
        'Chidi',
        'Dayo',
        'Eze',
      ]);
    });

    test('the same order applies while searching', () {
      final out = customerListView(all, {'4': -100}, 'd');
      // Chidi + Dayo contain "d"; Dayo owes so it leads.
      expect(_names(out), ['Dayo', 'Ada', 'Chidi']);
    });

    test('the walk-in is skipped', () {
      final out = customerListView([
        _c(Customer.walkInId, 'Walk-in', walkIn: true),
        ada,
      ], const {}, '');
      expect(_names(out), ['Ada']);
    });
  });

  group('customerListView search', () {
    test('matches the name, ignoring case and outer spaces', () {
      expect(_names(customerListView(all, const {}, '  BOL ')), ['Bola']);
    });

    test('matches the phone ignoring spaces and symbols', () {
      expect(_names(customerListView(all, const {}, '0803111')), ['Ada']);
      expect(_names(customerListView(all, const {}, '805 333')), ['Chidi']);
      expect(_names(customerListView(all, const {}, '234-805')), ['Chidi']);
    });

    test('a null phone never throws and never matches digits', () {
      expect(customerListView([bola], const {}, '0803'), isEmpty);
      expect(_names(customerListView([bola], const {}, '')), ['Bola']);
    });

    test('no match gives an empty list', () {
      expect(customerListView(all, const {}, 'zzz'), isEmpty);
    });
  });
}
