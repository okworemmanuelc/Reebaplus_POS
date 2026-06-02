import 'package:flutter/widgets.dart';

import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/features/payments/data/models/payment.dart';

class PaymentService extends ValueNotifier<List<Payment>> {
  PaymentService() : super(_initialPayments);

  static final List<Payment> _initialPayments = [];

  List<Payment> getAll() => List.unmodifiable(value);

  List<Payment> getByPeriod(String period) {
    final window = datePeriodFromLabel(period);
    if (window == DatePeriod.toDate) return getAll();
    final now = DateTime.now();
    return value.where((p) => window.includes(p.date, now: now)).toList();
  }

  List<Payment> getBySupplier(String supplierName) {
    return value.where((p) => p.supplierName == supplierName).toList();
  }

  double getTotalForPeriod(String period) {
    final payments = getByPeriod(period);
    return payments.fold(0.0, (sum, p) => sum + p.amount);
  }

  void addPayment(Payment payment) {
    value = [...value, payment];
  }

  void deletePayment(String id) {
    value = value.where((p) => p.id != id).toList();
  }
}

