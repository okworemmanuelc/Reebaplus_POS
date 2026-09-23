import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/crates/crate_count_store.dart';

/// #290 — which store a count belongs to without asking (PRD #284 stories
/// 32–34). Null means the sheet must make the user pick.
void main() {
  test('a locked store is used, whatever else the user could pick', () {
    expect(
      crateCountStoreWithoutAsking(
        lockedStoreId: 'b',
        selectableStoreIds: const ['a', 'b', 'c'],
      ),
      'b',
    );
  });

  test('All Stores on a one-store business uses that store without asking', () {
    expect(
      crateCountStoreWithoutAsking(
        lockedStoreId: null,
        selectableStoreIds: const ['only'],
      ),
      'only',
    );
  });

  test('All Stores on a multi-store business must ask', () {
    expect(
      crateCountStoreWithoutAsking(
        lockedStoreId: null,
        selectableStoreIds: const ['a', 'b'],
      ),
      isNull,
    );
  });

  test('no store at all must ask (and so records nothing)', () {
    expect(
      crateCountStoreWithoutAsking(
        lockedStoreId: null,
        selectableStoreIds: const [],
      ),
      isNull,
    );
  });
}
