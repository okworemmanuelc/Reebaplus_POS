import 'package:reebaplus_pos/core/data/area_selection.dart';
import 'package:reebaplus_pos/core/data/countries.dart';
import 'package:reebaplus_pos/core/data/nigerian_lgas.dart';
import 'package:reebaplus_pos/core/data/nigerian_states.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';

/// Offline write boundary for a store's online settings (#423). Every call
/// re-checks [Gates.manageOnlineStore] against the effective context before
/// touching the DAO, then writes Drift + the outbox in one transaction.
class StoreOnlineService {
  const StoreOnlineService(this._stores);

  final StoresDao _stores;

  static const _denied = 'You no longer have access to Manage online store.';

  /// True when [area] is a Nigerian state/LGA pair from the bundled lists
  /// (which match cloud `ng_areas`), or any non-empty free-text foreign area.
  /// [allowWholeState] admits a null LGA (delivery areas only).
  static bool isValidArea(AreaSelection area, {required bool allowWholeState}) {
    final state = area.state.trim();
    final lga = area.lga?.trim();
    if (state.isEmpty) return false;
    if (lga == null || lga.isEmpty) {
      if (!allowWholeState) return false;
      return area.country != kDefaultCountry || kNigerianStates.contains(state);
    }
    if (area.country != kDefaultCountry) return true;
    return kNigerianLgas[state]?.contains(lga) ?? false;
  }

  Future<Result<void, AppError>> _run(
    GateContext gateContext,
    Future<StoreOnlineBlockedReason?> Function() write,
  ) async {
    if (!Gates.manageOnlineStore.evaluate(gateContext)) {
      return Result.err(AppError.permission(_denied));
    }
    try {
      final blocked = await write();
      if (blocked != null) return Result.err(AppError.io(blocked.message));
      return Result.ok(null);
    } catch (error, stack) {
      CrashReporter.record(error, stack, context: 'stores.online_store');
      return Result.err(AppError.io('Could not save. Try again.'));
    }
  }

  Future<Result<void, AppError>> setArea({
    required String storeId,
    required AreaSelection area,
    required GateContext gateContext,
  }) {
    if (!isValidArea(area, allowWholeState: false)) {
      return Future.value(Result.err(AppError.io(
        StoreOnlineBlockedReason.needsArea.message)));
    }
    return _run(gateContext, () => _stores.setStoreArea(
      storeId: storeId, country: area.country, state: area.state, lga: area.lga!));
  }

  Future<Result<void, AppError>> setContact({
    required String storeId,
    required String phone,
    required String onlineNote,
    required GateContext gateContext,
  }) {
    if (onlineNote.trim().length > kStoreOnlineNoteMaxLength) {
      return Future.value(Result.err(AppError.io(
        'Keep the note to $kStoreOnlineNoteMaxLength characters.')));
    }
    return _run(gateContext, () => _stores.setStoreContact(
      storeId: storeId, phone: phone, onlineNote: onlineNote));
  }

  Future<Result<void, AppError>> addDeliveryArea({
    required String storeId,
    required AreaSelection area,
    required GateContext gateContext,
  }) {
    if (!isValidArea(area, allowWholeState: true)) {
      return Future.value(Result.err(AppError.io(
        StoreOnlineBlockedReason.needsArea.message)));
    }
    return _run(gateContext, () => _stores.addDeliveryArea(
      storeId: storeId, country: area.country, state: area.state, lga: area.lga));
  }

  Future<Result<void, AppError>> removeDeliveryArea({
    required String storeId,
    required String areaId,
    required GateContext gateContext,
  }) => _run(gateContext,
      () => _stores.removeDeliveryArea(storeId: storeId, areaId: areaId));

  Future<Result<void, AppError>> setOnlineOrdering({
    required String storeId,
    required bool enabled,
    required GateContext gateContext,
  }) => _run(gateContext,
      () => _stores.setOnlineOrdering(storeId: storeId, enabled: enabled));
}
