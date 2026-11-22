// #839 S2 — SupabaseCloudTransport.fetchTable pages with a keyset cursor
// ("rows after the last row's (last_updated_at, id)"), never a growing OFFSET.
//
// A MockClient plays a tiny PostgREST: it applies the eq / gt / or filters the
// transport sends, orders by (last_updated_at, id) and honours `limit`, so the
// tests check both the requests and the rows that come back.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/services/cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';

/// Rows strictly after (t, i): the exact `or` shape the transport sends.
final _afterCursor = RegExp(
  r'^\(last_updated_at\.gt\."([^"]+)",'
  r'and\(last_updated_at\.eq\."([^"]+)",id\.gt\."([^"]+)"\)\)$',
);

class _FakePostgrest {
  _FakePostgrest(this.rows);

  final List<Map<String, dynamic>> rows;
  final List<Uri> requests = [];

  /// 0-based request numbers that time out instead of answering.
  final Set<int> timeOutRequests = {};

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url);
    if (timeOutRequests.contains(requests.length - 1)) {
      throw TimeoutException('fake page timeout');
    }
    final params = request.url.queryParametersAll;
    Iterable<Map<String, dynamic>> out = rows;

    for (final column in ['business_id', 'id']) {
      for (final f in params[column] ?? const <String>[]) {
        expect(f, startsWith('eq.'));
        out = out.where((r) => r[column] == f.substring(3));
      }
    }
    for (final f in params['last_updated_at'] ?? const <String>[]) {
      final gte = f.startsWith('gte.');
      expect(gte || f.startsWith('gt.'), isTrue, reason: f);
      final bound = DateTime.parse(f.substring(gte ? 4 : 3));
      out = out.where((r) {
        final lua = DateTime.parse(r['last_updated_at'] as String);
        return lua.isAfter(bound) || (gte && lua.isAtSameMomentAs(bound));
      });
    }
    for (final f in params['or'] ?? const <String>[]) {
      final m = _afterCursor.firstMatch(f);
      expect(m, isNotNull, reason: 'unexpected or filter: $f');
      final t = m!.group(1)!;
      expect(m.group(2), t);
      final i = m.group(3)!;
      out = out.where((r) {
        final lua = r['last_updated_at'] as String;
        return lua.compareTo(t) > 0 ||
            (lua == t && (r['id'] as String).compareTo(i) > 0);
      });
    }

    final sorted = out.toList()
      ..sort((a, b) {
        final c = (a['last_updated_at'] as String).compareTo(
          b['last_updated_at'] as String,
        );
        return c != 0 ? c : (a['id'] as String).compareTo(b['id'] as String);
      });
    final offset = int.parse(params['offset']?.single ?? '0');
    final limit = int.parse(params['limit']?.single ?? '${sorted.length}');
    final page = sorted.skip(offset).take(limit).toList();
    return http.Response(
      jsonEncode(page),
      200,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}

Map<String, dynamic> _row(String id, String lua, {String biz = 'B'}) => {
  'id': id,
  'business_id': biz,
  'last_updated_at': lua,
};

void main() {
  late _FakePostgrest server;
  late SupabaseClient client;
  late SupabaseCloudTransport transport;

  void serve(List<Map<String, dynamic>> rows) {
    server = _FakePostgrest(rows);
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: MockClient(server.handle),
    );
    transport = SupabaseCloudTransport(client);
  }

  tearDown(() => client.dispose());

  List<String> ids(List<dynamic> rows) => [
    for (final r in rows) (r as Map<String, dynamic>)['id'] as String,
  ];

  test('page 2 asks for rows after the last row, never an offset', () async {
    serve([
      for (var i = 1; i <= 25; i++)
        _row(
          'id-${i.toString().padLeft(2, '0')}',
          '2026-11-21T10:00:${i.toString().padLeft(2, '0')}.123456+00:00',
        ),
    ]);

    final pages = <int>[];
    final rows = await transport.fetchTable(
      TableQuery('orders', 'B', null, pageSize: 10, onPage: pages.add),
    );

    expect(rows, hasLength(25));
    expect(pages, [10, 10, 5]);
    expect(server.requests, hasLength(3));
    for (final url in server.requests) {
      expect(url.queryParameters.containsKey('offset'), isFalse);
      expect(url.queryParameters['limit'], '10');
      expect(
        url.queryParameters['order'],
        'last_updated_at.asc.nullslast,id.asc.nullslast',
      );
    }
    expect(server.requests.first.queryParameters.containsKey('or'), isFalse);
    // The cursor carries the raw timestamp string (microseconds and offset kept).
    expect(
      server.requests[1].queryParameters['or'],
      '(last_updated_at.gt."2026-11-21T10:00:10.123456+00:00",'
      'and(last_updated_at.eq."2026-11-21T10:00:10.123456+00:00",'
      'id.gt."id-10"))',
    );
    // A plain lower bound lets the server start its index scan at the cursor.
    expect(server.requests.first.queryParameters['last_updated_at'], isNull);
    expect(server.requests[1].queryParametersAll['last_updated_at'], [
      'gte.2026-11-21T10:00:10.123456+00:00',
    ]);
    // The `+` survives URL encoding instead of turning into a space.
    expect(server.requests[1].query, contains('%2B00'));
  });

  test('rows sharing a last_updated_at across a page boundary are neither '
      'skipped nor duplicated', () async {
    const same = '2026-11-21T10:00:00.5+00:00';
    final expected = [
      _row('a', '2026-11-21T09:00:00+00:00'),
      _row('b', same),
      _row('c', same),
      _row('d', same),
      _row('e', same),
      _row('f', same),
      _row('g', '2026-11-21T11:00:00+00:00'),
    ];
    serve(expected.reversed.toList());

    final rows = await transport.fetchTable(
      const TableQuery('order_items', 'B', null, pageSize: 3),
    );

    expect(ids(rows), ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
  });

  test('since filter is still applied on every page', () async {
    serve([
      _row('old', '2026-01-01T00:00:00+00:00'),
      for (var i = 1; i <= 4; i++) _row('n$i', '2026-06-0${i}T00:00:00+00:00'),
      _row('other-biz', '2026-06-01T00:00:00+00:00', biz: 'X'),
    ]);

    final rows = await transport.fetchTable(
      TableQuery('customers', 'B', DateTime.utc(2026, 2, 1), pageSize: 2),
    );

    expect(ids(rows), ['n1', 'n2', 'n3', 'n4']);
    for (final url in server.requests) {
      expect(url.queryParameters['business_id'], 'eq.B');
      expect(
        url.queryParametersAll['last_updated_at'],
        contains('gt.2026-02-01T00:00:00.000Z'),
      );
    }
    expect(
      server.requests.skip(1).every((u) => u.queryParameters['or'] != null),
      isTrue,
    );
  });

  test('a page timeout halves the page size and keeps the cursor', () async {
    serve([
      for (var i = 1; i <= 50; i++)
        _row(
          'id-${i.toString().padLeft(2, '0')}',
          '2026-11-21T10:00:${i.toString().padLeft(2, '0')}+00:00',
        ),
    ]);

    // Page 1 answers; the first page-2 request times out once.
    server.timeOutRequests.add(1);

    final rows = await transport.fetchTable(
      const TableQuery('stock_transactions', 'B', null, pageSize: 20),
    );

    expect(ids(rows), [
      for (var i = 1; i <= 50; i++) 'id-${i.toString().padLeft(2, '0')}',
    ]);
    final r = server.requests;
    expect(r[0].queryParameters['limit'], '20');
    // The timed-out request and its retry ask for the same cursor.
    expect(r[1].queryParameters['limit'], '20');
    expect(r[2].queryParameters['limit'], '10');
    expect(r[1].queryParameters['or'], isNotNull);
    expect(r[2].queryParameters['or'], r[1].queryParameters['or']);
    expect(r[2].queryParameters['or'], contains('id.gt."id-20"'));
    expect(r.every((u) => !u.queryParameters.containsKey('offset')), isTrue);
  });

  test('a timeout at the minimum page size propagates', () async {
    serve([_row('a', '2026-11-21T10:00:00+00:00')]);
    server.timeOutRequests.addAll([0, 1]);

    // 10 halves to 5, below the floor of 10, so the first timeout surfaces.
    await expectLater(
      transport.fetchTable(const TableQuery('orders', 'B', null, pageSize: 10)),
      throwsA(isA<TimeoutException>()),
    );
    expect(server.requests, hasLength(1));
  });

  test('businesses filters on id and ignores since', () async {
    serve([
      {'id': 'B', 'last_updated_at': '2020-01-01T00:00:00+00:00'},
      {'id': 'X', 'last_updated_at': '2020-01-01T00:00:00+00:00'},
    ]);

    final rows = await transport.fetchTable(
      TableQuery('businesses', 'B', DateTime.utc(2030), pageSize: 500),
    );

    expect(ids(rows), ['B']);
    final q = server.requests.single.queryParameters;
    expect(q['id'], 'eq.B');
    expect(q.containsKey('last_updated_at'), isFalse);
  });

  test('system_config stays a single unpaginated call', () async {
    serve([
      {'key': 'min_android_build', 'last_updated_at': '2026-01-01T00:00:00Z'},
    ]);

    final pages = <int>[];
    final rows = await transport.fetchTable(
      TableQuery('system_config', 'ANY', null, pageSize: 1, onPage: pages.add),
    );

    expect(rows, hasLength(1));
    expect(pages, [1]);
    final q = server.requests.single.queryParameters;
    for (final key in ['limit', 'offset', 'or', 'order', 'business_id']) {
      expect(q.containsKey(key), isFalse, reason: key);
    }
  });
}
