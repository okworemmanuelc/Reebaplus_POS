import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reebaplus_pos/core/services/auth_refresh_observer.dart';

final _refresh = Uri.parse(
  'https://x.supabase.co/auth/v1/token?grant_type=refresh_token',
);

AuthRefreshObserverClient _client(int status, String body, {DateTime? now}) =>
    AuthRefreshObserverClient(
      MockClient((_) async => http.Response(body, status)),
      now: now == null ? null : () => now,
    );

void main() {
  setUp(() => AuthRefreshObserverClient.last = null);

  test('a refused refresh is remembered and the body still reaches the caller',
      () async {
    final body = jsonEncode({
      'code': 400,
      'error_code': 'refresh_token_already_used',
      'msg': 'Invalid Refresh Token: Already Used',
    });
    final res = await _client(400, body).post(
      _refresh,
      body: jsonEncode({'refresh_token': 'SECRET-TOKEN'}),
    );

    expect(res.statusCode, 400);
    expect(res.body, body);
    final last = AuthRefreshObserverClient.last!;
    expect(last.status, 400);
    expect(last.code, 'refresh_token_already_used');
    expect(last.describe(), isNot(contains('SECRET-TOKEN')));
  });

  test('a rate-limit refusal is remembered', () async {
    await _client(429, '{"error_code":"over_request_rate_limit"}')
        .post(_refresh);
    expect(AuthRefreshObserverClient.last!.status, 429);
    expect(AuthRefreshObserverClient.last!.code, 'over_request_rate_limit');
  });

  test('a body that is not JSON still records the status', () async {
    await _client(403, '<html>blocked</html>').post(_refresh);
    expect(AuthRefreshObserverClient.last!.status, 403);
    expect(AuthRefreshObserverClient.last!.code, isNull);
  });

  test('a successful refresh, a server error and other calls are ignored',
      () async {
    await _client(200, '{}').post(_refresh);
    await _client(503, '{}').post(_refresh);
    await _client(400, '{"error_code":"otp_expired"}').post(
      Uri.parse('https://x.supabase.co/auth/v1/token?grant_type=password'),
    );
    await _client(401, '{}').get(
      Uri.parse('https://x.supabase.co/rest/v1/products'),
    );
    expect(AuthRefreshObserverClient.last, isNull);
  });

  test('reasonAt only blames a recent refusal', () async {
    final t = DateTime(2026, 11, 12, 8);
    await _client(400, '{"error_code":"session_expired"}', now: t)
        .post(_refresh);
    expect(
      AuthRefreshObserverClient.reasonAt(t.add(const Duration(minutes: 10))),
      contains('session_expired'),
    );
    expect(
      AuthRefreshObserverClient.reasonAt(t.add(const Duration(hours: 2))),
      'unknown',
    );
  });

  test('reasonAt is unknown when nothing was refused', () {
    expect(AuthRefreshObserverClient.reasonAt(DateTime.now()), 'unknown');
  });
}
