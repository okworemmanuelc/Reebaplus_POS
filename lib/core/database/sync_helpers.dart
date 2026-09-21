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
    return _defaultSerializer.toJson<T>(value);
  }

  @override
  T fromJson<T>(dynamic json) {
    return _defaultSerializer.fromJson<T>(json);
  }
}

const _cloudSerializer = CloudValueSerializer();

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
    }
    return MapEntry(snakeKey, val);
  });
}
