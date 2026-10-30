import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/services/device_teardown.dart';

/// #573 — every leave reason runs its steps in the fixed order, and the
/// per-reason flags are the only difference between paths.
void main() {
  late List<String> steps;
  late DeviceTeardown teardown;
  Object? gateError;
  Object? clearError;

  setUp(() {
    steps = [];
    gateError = null;
    clearError = null;
    teardown = DeviceTeardown(
      assertOutboxClear: (biz) async {
        steps.add('gate:$biz');
        if (gateError != null) throw gateError!;
      },
      recordWipeLoss: (biz, reason) async => steps.add('loss:$biz:$reason'),
      discardUnsynced: (biz) async {
        steps.add('discard:$biz');
        return 3;
      },
      clearAllData: () async {
        steps.add('clear');
        if (clearError != null) throw clearError!;
      },
      signOut: () async => steps.add('signOut'),
      clearFirstLoadMarkers: () async => steps.add('markers'),
    );
  });

  Future<void> detach() async => steps.add('detach');

  test('logout: gate → clear → sign out → markers', () async {
    await teardown.leave(LeaveReason.logout, businessId: 'b');
    expect(steps, ['gate:b', 'clear', 'signOut', 'markers']);
  });

  test('logoutDiscardingUnsynced: loss → discard → clear → sign out → markers',
      () async {
    await teardown.leave(LeaveReason.logoutDiscardingUnsynced, businessId: 'b');
    expect(steps, [
      'loss:b:logout:user_discarded_unsynced',
      'discard:b',
      'clear',
      'signOut',
      'markers',
    ]);
  });

  test('resign: gate → detach → clear → sign out → markers', () async {
    await teardown.leave(LeaveReason.resign, businessId: 'b', detach: detach);
    expect(steps, ['gate:b', 'detach', 'clear', 'signOut', 'markers']);
  });

  test('resignDiscardingUnsynced: detach → loss → discard → wipe', () async {
    await teardown.leave(
      LeaveReason.resignDiscardingUnsynced,
      businessId: 'b',
      detach: detach,
    );
    expect(steps, [
      'detach',
      'loss:b:resign:user_discarded_unsynced',
      'discard:b',
      'clear',
      'signOut',
      'markers',
    ]);
  });

  test('ownerDeletedBusiness: detach → loss → clear → sign out → markers',
      () async {
    await teardown.leave(
      LeaveReason.ownerDeletedBusiness,
      businessId: 'b',
      detach: detach,
    );
    expect(steps, [
      'detach',
      'loss:b:business_deleted:owner_delete',
      'clear',
      'signOut',
      'markers',
    ]);
  });

  test('businessDeletedRemotely: loss → clear → sign out → markers', () async {
    await teardown.leave(LeaveReason.businessDeletedRemotely, businessId: 'b');
    expect(steps, [
      'loss:b:business_deleted:active',
      'clear',
      'signOut',
      'markers',
    ]);
  });

  test('businessDeletedRemotely with no resolved tenant skips the loss record',
      () async {
    await teardown.leave(LeaveReason.businessDeletedRemotely);
    expect(steps, ['clear', 'signOut', 'markers']);
  });

  test('sessionKicked: sign out only', () async {
    await teardown.leave(LeaveReason.sessionKicked);
    expect(steps, ['signOut']);
  });

  test('a throwing gate stops before anything local is touched', () async {
    gateError = Exception('unsynced');
    await expectLater(
      teardown.leave(LeaveReason.resign, businessId: 'b', detach: detach),
      throwsException,
    );
    expect(steps, ['gate:b']);
  });

  test('a throwing detach stops before loss/discard/wipe', () async {
    await expectLater(
      teardown.leave(
        LeaveReason.resignDiscardingUnsynced,
        businessId: 'b',
        detach: () async => throw Exception('rpc'),
      ),
      throwsException,
    );
    expect(steps, isEmpty);
  });

  test('a failed wipe never blocks the sign-out', () async {
    clearError = Exception('disk');
    await teardown.leave(LeaveReason.logout, businessId: 'b');
    expect(steps, ['gate:b', 'clear', 'signOut', 'markers']);
  });
}
