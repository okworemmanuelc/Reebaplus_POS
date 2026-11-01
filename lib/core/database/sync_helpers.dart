import 'dart:convert';

import 'package:drift/drift.dart';

/// Converts a camelCase string to snake_case. If the string already contains
/// underscores or contains no uppercase letters, it is returned as is.
String camelToSnake(String input) {
  if (input.contains('_')) return input;
  final exp = RegExp(r'(?<=[a-z0-9])([A-Z])');
  return input.replaceAllMapped(exp, (m) => '_${m.group(1)!}').toLowerCase();
}

/// A Drift [ValueSerializer] that serializes [DateTime] values to UTC ISO-8601
/// strings with an explicit `Z` zone designator (e.g. `2026-09-13T22:22:03.000Z`).
///
/// Drift's default `ValueSerializer.defaults(serializeDateTimeValuesAsString: true)`
/// calls `value.toIso8601String()` without `.toUtc()`. Because Drift reads
/// unix-seconds columns back from SQLite as local `DateTime`s, the default
/// serializer emits zone-less strings (e.g. `2026-09-13T23:22:03.000`). Postgres
/// interprets zone-less `timestamptz` literals as UTC, which shifts records from
/// devices in non-UTC time zones (such as Nigeria / WAT, UTC+1) forward by their
/// offset (#286).
class CloudValueSerializer extends ValueSerializer {
  const CloudValueSerializer();

  static const _defaultSerializer = ValueSerializer.defaults(
    serializeDateTimeValuesAsString: true,
  );

  @override
  dynamic toJson<T>(T value) {
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    if (value is double) return _wholeAsInt(value);
    return _defaultSerializer.toJson<T>(value);
  }

  @override
  T fromJson<T>(dynamic json) {
    return _defaultSerializer.fromJson<T>(json);
  }
}

const _cloudSerializer = CloudValueSerializer();

/// Quarter quantities (#627) are RealColumns, so a whole stock count like `5`
/// is a Dart `5.0`, which `jsonEncode` writes as `5.0`. A cloud `integer`
/// column (before migration 0239) or an RPC `::int` cast rejects `5.0`, and an
/// older app version could mis-read it. Whole doubles therefore go out as
/// JSON integers (`5`); `0.5` stays `0.5`. Safe for every other real column
/// too: Postgres `double precision` / `numeric` accept `5`.
dynamic _wholeAsInt(double v) =>
    v.isFinite && v == v.roundToDouble() && v.abs() < 9007199254740992
    ? v.toInt()
    : v;

/// `jsonEncode` for outbox / RPC payloads: every whole-valued double (a `5.0`
/// stock quantity) is written as a JSON integer (`5`), nested maps and lists
/// included. See [_wholeAsInt] for why. Fractions (`0.5`) pass through.
String encodeSyncPayload(Object? payload) =>
    jsonEncode(_normalizeWholeNumbers(payload));

dynamic _normalizeWholeNumbers(dynamic v) {
  if (v is double) return _wholeAsInt(v);
  if (v is Map) {
    return {for (final e in v.entries) e.key: _normalizeWholeNumbers(e.value)};
  }
  if (v is List) return [for (final e in v) _normalizeWholeNumbers(e)];
  return v;
}

/// Robust serialization helper to extract cloud-ready key-value maps
/// from any Drift `Insertable` (supporting both `DataClass` and `Companion`).
Map<String, dynamic> serializeInsertable(Insertable row) {
  final Map<String, dynamic> rawMap;
  if (row is DataClass) {
    rawMap =
        (row as dynamic).toJson(serializer: _cloudSerializer)
            as Map<String, dynamic>;
  } else {
    final columns = row.toColumns(true);
    rawMap = columns.map((k, v) {
      if (v is Variable) {
        return MapEntry(k, v.value);
      } else if (v is Constant) {
        return MapEntry(k, v.value);
      } else {
        return MapEntry(k, null);
      }
    });
  }

  // Convert keys to snake_case. DateTime → ISO-8601 conversion still needed
  // for the Companion path (Variable.value preserves the raw DateTime).
  return rawMap.map((k, v) {
    final snakeKey = camelToSnake(k);
    var val = v;
    if (val is DateTime) {
      val = _cloudSerializer.toJson(val);
    } else if (val is double) {
      val = _wholeAsInt(val);
    }
    return MapEntry(snakeKey, val);
  });
}
