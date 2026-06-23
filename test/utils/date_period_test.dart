import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';

void main() {
  // Fixed reference instant so the calendar boundaries are deterministic.
  // 2026-06-03 is a Wednesday; its Sunday-start week begins 2026-05-31.
  // Built as a LOCAL DateTime so it matches how `startFrom` constructs
  // boundaries (local date parts), independent of the runner's timezone.
  final now = DateTime(2026, 6, 3, 12, 0, 0);

  group('canonical labels', () {
    test('kDatePeriodLabels is the agreed set, in order', () {
      expect(kDatePeriodLabels, [
        'Today',
        'This Week',
        'This Month',
        'This Year',
        'To Date',
        'Custom',
      ]);
    });

    test('every enum value maps to its canonical label and back', () {
      for (final p in DatePeriod.values) {
        expect(datePeriodFromLabel(p.label), p);
      }
    });
  });

  group('datePeriodFromLabel tolerates legacy / rolling labels', () {
    test('Today / Day / Last 24 hours -> today', () {
      expect(datePeriodFromLabel('Today'), DatePeriod.today);
      expect(datePeriodFromLabel('Day'), DatePeriod.today);
      expect(datePeriodFromLabel('Last 24 hours'), DatePeriod.today);
    });
    test('This Week / Week / 7 Days / Last 7 days -> thisWeek', () {
      expect(datePeriodFromLabel('This Week'), DatePeriod.thisWeek);
      expect(datePeriodFromLabel('Week'), DatePeriod.thisWeek);
      expect(datePeriodFromLabel('7 Days'), DatePeriod.thisWeek);
      expect(datePeriodFromLabel('Last 7 days'), DatePeriod.thisWeek);
    });
    test('This Month / Month / 30 Days / This Quarter / Last 30 days -> thisMonth',
        () {
      expect(datePeriodFromLabel('This Month'), DatePeriod.thisMonth);
      expect(datePeriodFromLabel('Month'), DatePeriod.thisMonth);
      expect(datePeriodFromLabel('30 Days'), DatePeriod.thisMonth);
      expect(datePeriodFromLabel('This Quarter'), DatePeriod.thisMonth);
      expect(datePeriodFromLabel('Last 30 days'), DatePeriod.thisMonth);
    });
    test('This Year / Year / Last year -> thisYear', () {
      expect(datePeriodFromLabel('This Year'), DatePeriod.thisYear);
      expect(datePeriodFromLabel('Year'), DatePeriod.thisYear);
      expect(datePeriodFromLabel('Last year'), DatePeriod.thisYear);
    });
    test('To Date / All / All Time / unknown -> toDate', () {
      expect(datePeriodFromLabel('To Date'), DatePeriod.toDate);
      expect(datePeriodFromLabel('All'), DatePeriod.toDate);
      expect(datePeriodFromLabel('All Time'), DatePeriod.toDate);
      expect(datePeriodFromLabel('something weird'), DatePeriod.toDate);
    });
    test('is case- and whitespace-insensitive', () {
      expect(datePeriodFromLabel('  THIS week '), DatePeriod.thisWeek);
    });
  });

  group('startFrom — calendar boundaries (anchored to now)', () {
    test('toDate is unbounded (null)', () {
      expect(DatePeriod.toDate.startFrom(now), isNull);
    });
    test('today starts at local midnight today', () {
      expect(DatePeriod.today.startFrom(now), DateTime(2026, 6, 3));
    });
    test('thisWeek starts at the most recent Sunday (Sunday-start week)', () {
      // Wednesday 2026-06-03 -> Sunday 2026-05-31.
      expect(DatePeriod.thisWeek.startFrom(now), DateTime(2026, 5, 31));
      expect(DatePeriod.thisWeek.startFrom(now)!.weekday, DateTime.sunday);
    });
    test('thisWeek on a Sunday starts that same Sunday', () {
      final sunday = DateTime(2026, 5, 31, 9, 0); // a Sunday
      expect(DatePeriod.thisWeek.startFrom(sunday), DateTime(2026, 5, 31));
    });
    test('thisWeek on a Saturday starts the previous Sunday', () {
      final saturday = DateTime(2026, 6, 6, 9, 0); // a Saturday
      expect(DatePeriod.thisWeek.startFrom(saturday), DateTime(2026, 5, 31));
    });
    test('thisMonth starts at the first of the month', () {
      expect(DatePeriod.thisMonth.startFrom(now), DateTime(2026, 6, 1));
    });
    test('thisYear starts at Jan 1', () {
      expect(DatePeriod.thisYear.startFrom(now), DateTime(2026, 1, 1));
    });
  });

  group('includes — calendar boundaries', () {
    test('today: midnight today in, one second before out, later today in', () {
      expect(DatePeriod.today.includes(DateTime(2026, 6, 3), now: now), isTrue);
      expect(
          DatePeriod.today.includes(
              DateTime(2026, 6, 2, 23, 59, 59),
              now: now),
          isFalse);
      expect(DatePeriod.today.includes(DateTime(2026, 6, 3, 11), now: now),
          isTrue);
    });

    test('thisWeek: Sunday start in, the moment before out', () {
      expect(DatePeriod.thisWeek.includes(DateTime(2026, 5, 31), now: now),
          isTrue);
      expect(
          DatePeriod.thisWeek
              .includes(DateTime(2026, 5, 30, 23, 59, 59), now: now),
          isFalse);
    });

    test('thisMonth: 1st in, last day of prior month out', () {
      expect(DatePeriod.thisMonth.includes(DateTime(2026, 6, 1), now: now),
          isTrue);
      expect(
          DatePeriod.thisMonth.includes(DateTime(2026, 5, 31, 23), now: now),
          isFalse);
    });

    test('thisYear: Jan 1 in, Dec 31 of prior year out', () {
      expect(DatePeriod.thisYear.includes(DateTime(2026, 1, 1), now: now),
          isTrue);
      expect(
          DatePeriod.thisYear.includes(DateTime(2025, 12, 31, 23), now: now),
          isFalse);
    });

    test('toDate includes everything, however old, and the future', () {
      expect(DatePeriod.toDate.includes(DateTime(1990), now: now), isTrue);
      expect(
          DatePeriod.toDate
              .includes(now.add(const Duration(days: 10)), now: now),
          isTrue);
    });
  });

  group('includes — zone handling', () {
    test('a UTC-zoned timestamp compares as the same instant', () {
      // 11:00 today expressed in UTC is still "in" today's window when `now`
      // is 12:00 — the helper normalises both to UTC before comparing.
      final utcEarlierToday = DateTime(2026, 6, 3, 11).toUtc();
      expect(DatePeriod.today.includes(utcEarlierToday, now: now), isTrue);
    });
  });

  group('datePeriodLabelsForRole', () {
    test('Manager-or-above gets the full six', () {
      expect(datePeriodLabelsForRole(managerUp: true), kDatePeriodLabels);
    });
    test('below Manager is capped to Today / This Week / This Month / Custom', () {
      expect(datePeriodLabelsForRole(managerUp: false),
          ['Today', 'This Week', 'This Month', 'Custom']);
    });
  });

  group('dateRangeForLabel', () {
    test('returns (start, null) for a bounded period', () {
      final (start, end) = dateRangeForLabel('This Month', now: now);
      expect(start, DateTime(2026, 6, 1));
      expect(end, isNull);
    });
    test('returns (null, null) for to date', () {
      final (start, end) = dateRangeForLabel('To Date', now: now);
      expect(start, isNull);
      expect(end, isNull);
    });
    test('correctly parses custom date-only ranges (no time/colons)', () {
      final (start, end) = dateRangeForLabel('Custom:2026-06-01:2026-06-23', now: now);
      expect(start, DateTime(2026, 6, 1));
      expect(end, DateTime(2026, 6, 23, 23, 59, 59, 999));
    });
    test('correctly parses custom date-time ranges (with time and colons)', () {
      final (start, end) = dateRangeForLabel('Custom:2026-06-01T00:00:00.000Z:2026-06-23T00:00:00.000Z', now: now);
      expect(start, DateTime(2026, 6, 1));
      expect(end, DateTime(2026, 6, 23, 23, 59, 59, 999));
    });
  });

  group('parseCustomDateRange', () {
    test('parses date-only format', () {
      final (start, end) = parseCustomDateRange('Custom:2026-06-01:2026-06-23');
      expect(start, DateTime(2026, 6, 1));
      expect(end, DateTime(2026, 6, 23));
    });
    test('parses ISO-8601 UTC format with colons', () {
      final (start, end) = parseCustomDateRange('Custom:2026-06-01T00:00:00.000Z:2026-06-23T00:00:00.000Z');
      expect(start, DateTime.utc(2026, 6, 1));
      expect(end, DateTime.utc(2026, 6, 23));
    });
    test('returns nulls for non-custom labels', () {
      final (start, end) = parseCustomDateRange('This Month');
      expect(start, isNull);
      expect(end, isNull);
    });
  });

  group('formatPeriodLabel', () {
    test('formats canonical periods unchanged', () {
      expect(formatPeriodLabel('Today'), 'Today');
      expect(formatPeriodLabel('This Month'), 'This Month');
    });
    test('formats custom date-only ranges', () {
      expect(formatPeriodLabel('Custom:2026-06-01:2026-06-23'), 'Jun 1, 2026 – Jun 23, 2026');
    });
    test('formats custom ISO ranges with colons', () {
      expect(formatPeriodLabel('Custom:2026-06-01T00:00:00.000Z:2026-06-23T00:00:00.000Z'), 'Jun 1, 2026 – Jun 23, 2026');
    });
  });
}
