import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// The Cancel restore-layer id must equal what the cloud recomputes in
/// `pos_recost_product_store` (migration 0228). Expected value captured from
/// production on 2026-10-26:
///   select extensions.uuid_generate_v5(extensions.uuid_ns_url(),
///     'cancel_restore:0190a2b4-0000-7000-8000-000000000001');
void main() {
  test('cancel restore layer id matches the cloud uuid_generate_v5', () {
    expect(
      CostBatchesDao.cancelRestoreLayerId(
        '0190a2b4-0000-7000-8000-000000000001',
      ),
      'feca5405-00c6-533a-8e5e-1b1395496185',
    );
  });
}
