class Staff {
  final String id;
  final String name;
  final String role; // ceo, manager, stock_keeper, cashier, rider

  Staff({
    required this.id,
    required this.name,
    required this.role,
  });
}

class StaffService {
  static final List<Staff> _staffList = [];

  List<Staff> getAll() => _staffList;

  List<Staff> getRiders() => _staffList.where((s) => s.role == 'rider').toList();
}

final staffService = StaffService();
