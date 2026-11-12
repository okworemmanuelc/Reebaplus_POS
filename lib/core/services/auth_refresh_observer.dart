import 'dart:convert';

import 'package:http/http.dart' as http;

/// Why the server refused to renew this phone's login (#796).
///
/// Holds the HTTP status and the server's error code and message only. Never
/// a token: the request body is not read.
class AuthRefreshRejection {
  const AuthRefreshRejection({
    required this.status,
    required this.at,
    this.code,
    this.message,
  });

  final int status;
  final String? code;
  final String? message;
  final DateTime at;

  /// Short text for an `error_logs` message.
  String describe() =>
      'status=$status, code=${code ?? 'none'}, msg=${message ?? 'none'}';
}

/// Remembers the last refused login renewal (#796).
///
/// The auth library signs the phone out on ANY non-retryable refusal of a
/// token refresh and discards the reason, so the app only ever saw a bare
/// `signedOut`. This client sits under the Supabase client, watches only the
/// refresh call, and keeps the server's answer so the `auth.session_lost` and
/// `auth.session_expired_gate` records can say why.
class AuthRefreshObserverClient extends http.BaseClient {
  AuthRefreshObserverClient(this._inner, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final http.Client _inner;
  final DateTime Function() _now;

  /// The most recent refusal, or null when none happened on this run.
  static AuthRefreshRejection? last;

  /// How long a refusal stays attributable to a lost session. Long enough
  /// for a cold start: the refusal lands on the PIN screen and the gate only
  /// renders once the PIN is entered.
  static const Duration freshFor = Duration(minutes: 30);

  /// The last refusal as log text when it is recent enough to be the cause of
  /// a session lost at [at]; otherwise `unknown`.
  static String reasonAt(DateTime at) {
    final r = last;
    if (r == null || at.difference(r.at).abs() > freshFor) return 'unknown';
    return r.describe();
  }

  static bool _isRefresh(Uri url) =>
      url.path.endsWith('/auth/v1/token') &&
      url.queryParameters['grant_type'] == 'refresh_token';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    // 5xx and network errors are retried by the library and never sign the
    // phone out, so only a 4xx on the refresh call is a refusal.
    final refused = response.statusCode >= 400 && response.statusCode < 500;
    if (!refused || !_isRefresh(request.url)) return response;

    final bytes = await response.stream.toBytes();
    try {
      last = _parse(response.statusCode, bytes);
    } catch (_) {
      last = AuthRefreshRejection(status: response.statusCode, at: _now());
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  AuthRefreshRejection _parse(int status, List<int> bytes) {
    String? code;
    String? message;
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is Map) {
      code = _text(decoded['error_code'] ?? decoded['code'] ?? decoded['error']);
      message = _text(
        decoded['msg'] ?? decoded['message'] ?? decoded['error_description'],
      );
    }
    return AuthRefreshRejection(
      status: status,
      code: code,
      message: message,
      at: _now(),
    );
  }

  static String? _text(Object? v) {
    if (v == null) return null;
    final s = v.toString();
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  @override
  void close() => _inner.close();
}
