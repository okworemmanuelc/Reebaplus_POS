import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';

/// Resolve an IANA timezone name to a [Location], falling back to UTC.
Location resolveLocation(String tzName) {
  try {
    return getLocation(tzName);
  } on LocationNotFoundException {
    debugPrint('[business_time] Invalid timezone "$tzName"; using UTC');
    return UTC;
  }
}

/// Look up the configured timezone IANA name for [businessId]. Returns
/// `'UTC'` if the row is missing.
Future<String> getBusinessTimezone(AppDatabase db, String businessId) async {
  final row = await (db.select(
    db.businesses,
  )..where((b) => b.id.equals(businessId))).getSingleOrNull();
  return row?.timezone ?? 'UTC';
}

Future<Location> _businessLocation(AppDatabase db, String businessId) async {
  return resolveLocation(await getBusinessTimezone(db, businessId));
}

/// Synchronous variant for client-side filters that have already loaded the
/// timezone name. Returns the UTC instant corresponding to local midnight on
/// the day containing [localNow].
DateTime localDayStartUtc(DateTime localNow, String tzName) {
  final loc = resolveLocation(tzName);
  final l = TZDateTime.from(localNow, loc);
  return TZDateTime(loc, l.year, l.month, l.day).toUtc();
}

/// Synchronous variant: UTC instant for a specific local Y/M/D in [tzName].
DateTime localDateUtc(int year, int month, int day, String tzName) {
  return TZDateTime(resolveLocation(tzName), year, month, day).toUtc();
}

/// Duration from [instant] until the start of the NEXT local calendar day in
/// [tzName] (the next business-day boundary). Used to self-invalidate "today"
/// on an always-on till so it re-gates and re-buckets sales across midnight
/// instead of staying stuck on the day the app was opened.
Duration untilNextBusinessDay(DateTime instant, String tzName) {
  final loc = resolveLocation(tzName);
  final l = TZDateTime.from(instant, loc);
  final nextMidnight = TZDateTime(
    loc,
    l.year,
    l.month,
    l.day,
  ).add(const Duration(days: 1));
  return nextMidnight.difference(l);
}

/// The local business-day calendar date as `YYYY-MM-DD` for [instant] in
/// [tzName]. The Funds Register keys its daily open/close + ledger buckets on
/// this string so "today" is the business's local day, not the device clock's.
String businessDateString(DateTime instant, String tzName) {
  final l = TZDateTime.from(instant, resolveLocation(tzName));
  final mm = l.month.toString().padLeft(2, '0');
  final dd = l.day.toString().padLeft(2, '0');
  return '${l.year}-$mm-$dd';
}

/// Returns the UTC half-open range `[utcStart, utcEnd)` covering the local
/// calendar day that contains [localDay] in the business's timezone.
///
/// Use for "today"-style filters on append-only ledger tables whose
/// `created_at` is stored in UTC. The naive `DateTime(y, m, d)` pattern
/// silently uses the device clock's local zone, so a sale recorded just
/// after local midnight in WAT (UTC+1) would be bucketed into the wrong
/// day on a phone set to a different zone.
Future<({DateTime utcStart, DateTime utcEnd})> businessDayUtcRange(
  AppDatabase db,
  String businessId,
  DateTime localDay,
) async {
  final loc = await _businessLocation(db, businessId);
  final start = TZDateTime(loc, localDay.year, localDay.month, localDay.day);
  final end = start.add(const Duration(days: 1));
  return (utcStart: start.toUtc(), utcEnd: end.toUtc());
}

/// Returns the UTC half-open range `[utcStart, utcEnd)` for a custom local
/// span. [localStart] is inclusive at midnight; [localEnd] is exclusive at
/// midnight (pass `localEnd = localStart + N days` for an N-day window).
Future<({DateTime utcStart, DateTime utcEnd})> businessRangeUtc(
  AppDatabase db,
  String businessId,
  DateTime localStart,
  DateTime localEnd,
) async {
  final loc = await _businessLocation(db, businessId);
  final start = TZDateTime(
    loc,
    localStart.year,
    localStart.month,
    localStart.day,
  );
  final end = TZDateTime(loc, localEnd.year, localEnd.month, localEnd.day);
  return (utcStart: start.toUtc(), utcEnd: end.toUtc());
}
