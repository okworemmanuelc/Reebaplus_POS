import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';

void main() {
  // Fixed reference instant so the rolling windows are deterministic.
  final now = DateTime.utc(2026, 6, 1, 12, 0, 0);

  group('canonical labels', () {
    test('kDatePeriodLabels is the agreed set, in order', () {
      expect(kDatePeriodLabels, [
        'Last 24 hours',
        'Last 7 days',
        'Last 30 days',
        'Last year',
        'To date',
      ]);
    });

    test('every enum value maps to its canonical label and back', () {
      for (final p in DatePeriod.values) {
        expect(datePeriodFromLabel(p.label), p);
      }
    });
  });

  group('datePeriodFromLabel tolerates legacy labels', () {
    test('Day / Today -> last24Hours', () {
      expect(datePeriodFromLabel('Day'), DatePeriod.last24Hours);
      expect(datePeriodFromLabel('Today'), DatePeriod.last24Hours);
    });
    test('Week / This Week / 7 Days -> last7Days', () {
      expect(datePeriodFromLabel('Week'), DatePeriod.last7Days);
      expect(datePeriodFromLabel('This Week'), DatePeriod.last7Days);
      expect(datePeriodFromLabel('7 Days'), DatePeriod.last7Days);
    });
    test('Month / This Month / 30 Days / This Quarter -> last30Days', () {
      expect(datePeriodFromLabel('Month'), DatePeriod.last30Days);
      expect(datePeriodFromLabel('This Month'), DatePeriod.last30Days);
      expect(datePeriodFromLabel('30 Days'), DatePeriod.last30Days);
      expect(datePeriodFromLabel('This Quarter'), DatePeriod.last30Days);
    });
    test('Year / This Year -> lastYear', () {
      expect(datePeriodFromLabel('Year'), DatePeriod.lastYear);
      expect(datePeriodFromLabel('This Year'), DatePeriod.lastYear);
    });
    test('To Date / All / All Time / unknown -> toDate', () {
      expect(datePeriodFromLabel('To Date'), DatePeriod.toDate);
      expect(datePeriodFromLabel('All'), DatePeriod.toDate);
      expect(datePeriodFromLabel('All Time'), DatePeriod.toDate);
      expect(datePeriodFromLabel('something weird'), DatePeriod.toDate);
    });
    test('is case- and whitespace-insensitive', () {
      expect(datePeriodFromLabel('  last 7 DAYS '), DatePeriod.last7Days);
    });
  });

  group('startFrom', () {
    test('toDate is unbounded (null)', () {
      expect(DatePeriod.toDate.startFrom(now), isNull);
    });
    test('windows subtract the right span', () {
      expect(DatePeriod.last24Hours.startFrom(now),
          now.subtract(const Duration(hours: 24)));
      expect(DatePeriod.last7Days.startFrom(now),
          now.subtract(const Duration(days: 7)));
      expect(DatePeriod.last30Days.startFrom(now),
          now.subtract(const Duration(days: 30)));
      expect(DatePeriod.lastYear.startFrom(now),
          now.subtract(const Duration(days: 365)));
    });
  });

  group('includes — boundaries (the bug we are fixing)', () {
    test('last 24 hours: 23h ago in, 25h ago out', () {
      expect(
          DatePeriod.last24Hours
              .includes(now.subtract(const Duration(hours: 23)), now: now),
          isTrue);
      expect(
          DatePeriod.last24Hours
              .includes(now.subtract(const Duration(hours: 25)), now: now),
          isFalse);
    });

    test('last 7 days: 6d ago in, exactly 7d in, 7d+1s out', () {
      expect(
          DatePeriod.last7Days
              .includes(now.subtract(const Duration(days: 6)), now: now),
          isTrue);
      // boundary is inclusive at exactly the start
      expect(
          DatePeriod.last7Days
              .includes(now.subtract(const Duration(days: 7)), now: now),
          isTrue);
      expect(
          DatePeriod.last7Days.includes(
              now.subtract(const Duration(days: 7, seconds: 1)),
              now: now),
          isFalse);
    });

    test('last 30 days: 29d in, 31d out', () {
      expect(
          DatePeriod.last30Days
              .includes(now.subtract(const Duration(days: 29)), now: now),
          isTrue);
      expect(
          DatePeriod.last30Days
              .includes(now.subtract(const Duration(days: 31)), now: now),
          isFalse);
    });

    test('last year: 364d in, 366d out', () {
      expect(
          DatePeriod.lastYear
              .includes(now.subtract(const Duration(days: 364)), now: now),
          isTrue);
      expect(
          DatePeriod.lastYear
              .includes(now.subtract(const Duration(days: 366)), now: now),
          isFalse);
    });

    test('to date includes everything, however old, and the future', () {
      expect(DatePeriod.toDate.includes(DateTime.utc(1990), now: now), isTrue);
      expect(
          DatePeriod.toDate
              .includes(now.add(const Duration(days: 10)), now: now),
          isTrue);
    });
  });

  group('includes — zone handling', () {
    test('a local-zoned timestamp compares as the same instant as UTC now', () {
      // 1 hour ago expressed in local time must be "in" the 24h window even
      // though `now` is UTC — the helper normalises both to UTC.
      final localOneHourAgo =
          now.toLocal().subtract(const Duration(hours: 1));
      expect(DatePeriod.last24Hours.includes(localOneHourAgo, now: now),
          isTrue);
    });
  });

  group('dateRangeForLabel', () {
    test('returns (start, null) for a bounded window', () {
      final (start, end) = dateRangeForLabel('Last 7 days', now: now);
      expect(start, now.subtract(const Duration(days: 7)));
      expect(end, isNull);
    });
    test('returns (null, null) for to date', () {
      final (start, end) = dateRangeForLabel('To date', now: now);
      expect(start, isNull);
      expect(end, isNull);
    });
  });
}
