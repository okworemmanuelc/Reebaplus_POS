import 'package:flutter/widgets.dart';
import 'package:reebaplus_pos/features/inventory/data/models/supplier.dart';
import 'package:reebaplus_pos/features/inventory/data/models/crate_group.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

class SupplierService extends ValueNotifier<List<Supplier>> {
  final AppDatabase _db;
  Map<String, CrateSizeGroupData> _crateSizeGroupsById = const {};
  List<SupplierData> _lastSuppliers = const [];

  SupplierService(this._db) : super([]) {
    _init();
  }

  void _init() {
    _db.inventoryDao.watchAllCrateSizeGroups().listen((groups) {
      _crateSizeGroupsById = {for (final g in groups) g.id: g};
      value = _lastSuppliers.map(_fromDb).toList();
    });
    _db.catalogDao.watchAllSupplierDatas().listen((dataList) {
      _lastSuppliers = dataList;
      value = dataList.map(_fromDb).toList();
    });
  }

  Supplier _fromDb(SupplierData d) {
    final cgName = d.crateSizeGroupId == null
        ? null
        : _crateSizeGroupsById[d.crateSizeGroupId!]?.name;
    return Supplier(
      id: d.id,
      name: d.name,
      crateGroup: _matchCrateGroupEnum(cgName),
      contactDetails: [
        d.phone,
        d.email,
        d.address,
      ].where((s) => s != null && s.isNotEmpty).join(', '),
    );
  }

  static CrateGroup _matchCrateGroupEnum(String? name) {
    if (name == null) return CrateGroup.nbPlc;
    final lower = name.toLowerCase();
    for (final g in CrateGroup.values) {
      if (g.label.toLowerCase() == lower) return g;
    }
    return CrateGroup.nbPlc;
  }

  List<Supplier> getAll() => List.unmodifiable(value);

  Supplier? getById(String id) {
    try {
      return value.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> addSupplier(Supplier supplier) async {
    // stub — no DB write
  }

  void updateSupplier(Supplier updatedSupplier) {
    final index = value.indexWhere((s) => s.id == updatedSupplier.id);
    if (index != -1) {
      final newList = List<Supplier>.from(value);
      newList[index] = updatedSupplier;
      value = newList;
    }
  }
}
