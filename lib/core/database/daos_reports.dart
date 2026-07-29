part of 'daos.dart';

/// The frozen figure set of one persisted day close (#174, PRD #155). A plain
/// value object at the DATABASE layer so the DAO never imports the features
/// layer (`recon_data.dart`): the Daily Reconciliation detail screen maps the
/// computed `ReconData` onto this before handing it to [DailyClosingsDao]. Every
/// field is a period-scoped figure (kobo, or a unit count) — the ones the
/// reconciliation cards badge an as-reviewed-vs-current delta on.
class DailyClosingFigures {
  const DailyClosingFigures({
    required this.totalSalesKobo,
    required this.refundsKobo,
    required this.discountsKobo,
    required this.cogsKobo,
    required this.grossProfitKobo,
    required this.netProfitKobo,
    required this.expensesKobo,
    required this.damagesCostKobo,
    required this.cashSalesKobo,
    required this.cashInKobo,
    required this.cashOutKobo,
    required this.netCashMovementKobo,
    required this.stockCogsKobo,
    required this.stockExpectedClosingKobo,
    required this.itemsSold,
    required this.shortageUnits,
  });

  final int totalSalesKobo;
  final int refundsKobo;
  final int discountsKobo;
  final int cogsKobo;
  final int grossProfitKobo;
  final int netProfitKobo;
  final int expensesKobo;
  final int damagesCostKobo;
  final int cashSalesKobo;
  final int cashInKobo;
  final int cashOutKobo;
  final int netCashMovementKobo;
  final int stockCogsKobo;
  final int stockExpectedClosingKobo;
  final int itemsSold;
  final int shortageUnits;
}

/// Persists + reads the `daily_closings` snapshots (#174, PRD #155, ADR 0021 §2,
/// scope fixed by #191 / ADR 0022).
///
/// The FIRST review of a FINISHED calendar day freezes its computed figure set
/// here (natural-key FIRST-WRITER-WINS on `(business_id, business_date)`);
/// re-opening the day — on this device or any other — never overwrites it. The
/// row id is DETERMINISTIC from the natural key so two offline devices mint the
/// same id and converge instead of duplicating. Purely observational: nothing
/// here changes a money flow or an existing figure.
///
/// **The frozen figures are always BUSINESS-WIDE (#191).** The natural key has no
/// store in it, so a snapshot captured in one store's scope would let whichever
/// scope opened the day first decide that day's baseline forever — and leave
/// every other scope with no baseline at all. `store_scope_id` is therefore
/// always written NULL (= business-wide) and never read back: a legacy non-null
/// value predates this rule and is read as business-wide too.
@DriftAccessor(tables: [DailyClosings])
class DailyClosingsDao extends DatabaseAccessor<AppDatabase>
    with _$DailyClosingsDaoMixin, BusinessScopedDao<AppDatabase> {
  DailyClosingsDao(super.db);

  /// The deterministic id for a `(business, day)` snapshot. Both devices derive
  /// the SAME UUID from the natural key ([UuidV7.deterministic]) so a
  /// first-writer-wins insert converges instead of racing two ids to a UNIQUE
  /// collision (2067). See [[project_synced_write_explicit_id]].
  static String snapshotId(String businessId, String businessDate) =>
      UuidV7.deterministic('daily_closing:$businessId:$businessDate');

  /// Freezes [figures] as the snapshot for [businessDate] IF no snapshot exists
  /// yet (first-writer-wins) — otherwise a no-op that leaves the existing row
  /// untouched (re-opening never overwrites). Returns the snapshot id either way.
  ///
  /// A newly-written row is enqueued for sync; a no-op enqueues nothing, so a
  /// re-open produces no churn. The write sets an explicit `id` + every
  /// DB-defaulted column so the pushed payload is complete (a missing default
  /// would make the cloud mint a different id → 2067, or reject on NOT NULL →
  /// 23502 — see [[project_synced_write_explicit_id]]).
  Future<String> snapshotIfAbsent({
    required String businessDate,
    required DailyClosingFigures figures,
    String? reviewedBy,
  }) async {
    final businessId = requireBusinessId();
    final id = snapshotId(businessId, businessDate);
    return transaction(() async {
      final existing = await (select(dailyClosings)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (existing != null) return existing.id; // first-writer-wins — no clobber

      final now = DateTime.now();
      final row = DailyClosingsCompanion.insert(
        id: Value(id),
        businessId: businessId,
        businessDate: businessDate,
        // #191 — business-wide by construction. Explicit rather than Absent so
        // the pushed payload is complete (see [[project_synced_write_explicit_id]]).
        storeScopeId: const Value(null),
        totalSalesKobo: Value(figures.totalSalesKobo),
        refundsKobo: Value(figures.refundsKobo),
        discountsKobo: Value(figures.discountsKobo),
        cogsKobo: Value(figures.cogsKobo),
        grossProfitKobo: Value(figures.grossProfitKobo),
        netProfitKobo: Value(figures.netProfitKobo),
        expensesKobo: Value(figures.expensesKobo),
        damagesCostKobo: Value(figures.damagesCostKobo),
        cashSalesKobo: Value(figures.cashSalesKobo),
        cashInKobo: Value(figures.cashInKobo),
        cashOutKobo: Value(figures.cashOutKobo),
        netCashMovementKobo: Value(figures.netCashMovementKobo),
        stockCogsKobo: Value(figures.stockCogsKobo),
        stockExpectedClosingKobo: Value(figures.stockExpectedClosingKobo),
        itemsSold: Value(figures.itemsSold),
        shortageUnits: Value(figures.shortageUnits),
        reviewedBy: Value(reviewedBy),
        reviewedAt: Value(now),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      // insertOrIgnore is a second belt against a same-instant cross-isolate
      // race: if a twin landed between the SELECT and here, the id PK conflict
      // ignores rather than throws. The enqueue still rides the intended write.
      await into(dailyClosings).insert(row, mode: InsertMode.insertOrIgnore);
      await db.syncDao.enqueueUpsert('daily_closings', row);
      return id;
    });
  }

  /// The persisted snapshot for [businessDate], or null when the day has not
  /// been reviewed yet. Business-scoped; at most one row exists per day
  /// (first-writer-wins), so this reads that single row reactively. The day is
  /// the whole key — `storeScopeId` is never a filter here (#191), so a legacy
  /// row frozen inside one store's scope still surfaces at every scope.
  Stream<DailyClosingData?> watchForDay(String businessDate) {
    return (select(dailyClosings)
          ..where(
            (t) => whereBusiness(t) & t.businessDate.equals(businessDate),
          )
          ..limit(1))
        .watchSingleOrNull();
  }

  /// One-shot read of [businessDate]'s snapshot (null when unreviewed).
  Future<DailyClosingData?> getForDay(String businessDate) {
    return (select(dailyClosings)
          ..where(
            (t) => whereBusiness(t) & t.businessDate.equals(businessDate),
          )
          ..limit(1))
        .getSingleOrNull();
  }
}
