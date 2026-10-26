import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/services/push_messaging_port.dart';
import 'package:reebaplus_pos/shared/services/online_order_push_route.dart';

void main() {
  test('PushMessage parses an online_order push', () {
    const m = PushMessage(data: {
      'type': 'online_order',
      'online_order_id': 'oo-1',
      'store_id': 's-1',
      'audience': 'staff',
    });
    expect(m.isOnlineOrder, isTrue);
    expect(m.onlineOrderId, 'oo-1');
    expect(m.storeId, 's-1');
    expect(m.isConsoleBroadcast, isFalse);
  });

  test('order already local opens the detail', () async {
    String? detail;
    var tab = 0;
    final t = await routeOnlineOrderTap(
      onlineOrderId: 'oo-1',
      isLocal: (_) async => true,
      openDetail: (id) => detail = id,
      openOnlineTab: () => tab++,
    );
    expect(t, OnlineOrderTapTarget.detail);
    expect(detail, 'oo-1');
    expect(tab, 0);
  });

  test('order not yet pulled opens the Online tab', () async {
    String? detail;
    var tab = 0;
    final t = await routeOnlineOrderTap(
      onlineOrderId: 'oo-1',
      isLocal: (_) async => false,
      openDetail: (id) => detail = id,
      openOnlineTab: () => tab++,
    );
    expect(t, OnlineOrderTapTarget.onlineTab);
    expect(detail, isNull);
    expect(tab, 1);
  });

  test('missing id or a throwing lookup falls back to the tab, never throws',
      () async {
    var tab = 0;
    expect(
      await routeOnlineOrderTap(
        onlineOrderId: null,
        isLocal: (_) async => true,
        openDetail: (_) {},
        openOnlineTab: () => tab++,
      ),
      OnlineOrderTapTarget.onlineTab,
    );
    expect(
      await routeOnlineOrderTap(
        onlineOrderId: 'x',
        isLocal: (_) async => throw StateError('db'),
        openDetail: (_) {},
        openOnlineTab: () => tab++,
      ),
      OnlineOrderTapTarget.onlineTab,
    );
    expect(tab, 2);
  });
}
