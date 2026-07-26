import 'dart:convert';
import 'dart:math' as math;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:reebaplus_pos/core/costing/fifo_drawdown.dart';
import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/business_scoped_dao.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/database/sync_helpers.dart';
// #141: the van predicate. The DAO layer normally takes van-ness as an id set
// from its caller (see `OrdersDao._outsideStores`), but the two van WRITE
// boundaries — dispatching a load and refusing a van leg's cancel — only ever
// hold a store id, and a write-boundary guard must not depend on the UI having
// asked the right question. They resolve the row and run the ONE predicate
// rather than comparing `kind` inline.
import 'package:reebaplus_pos/core/stores/van_store.dart';
// #144: the van-remittance activity-log line states the amount, and money is
// rendered through the app-wide formatter (never a hardcoded symbol) so it
// follows the CEO-chosen currency. Pure formatting — no provider dependency.
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/order_number.dart';
// #145: the trip reconciliation math is a PURE function over plain data (spec
// §6 / §13 seam 1). The DAO assembles its four inputs and the close write reads
// its answer — no arithmetic lives here, so the screen, the write and the
// fixture suite can never disagree about what a driver owes.
import 'package:reebaplus_pos/core/van_sales/van_trip_position.dart';
// #142: the driver terminal's run-sales figure must use the canonical revenue
// predicate, never a bare `status == 'completed'`
// ([[project_revenue_recognized_at_checkout]]).
import 'package:reebaplus_pos/shared/models/order_status.dart';

part 'daos.g.dart';

part 'daos_catalog.dart';
part 'daos_inventory.dart';
part 'daos_costing.dart';
part 'daos_orders.dart';
part 'daos_payments.dart';
part 'daos_customers.dart';
part 'daos_suppliers.dart';
part 'daos_crates.dart';
part 'daos_expenses.dart';
part 'daos_sync_diagnostics.dart';
part 'daos_stores_sessions.dart';
part 'daos_van_sales.dart';
part 'daos_permissions.dart';
part 'daos_org.dart';
part 'daos_reports.dart';

/// Sentinel for "argument was not provided" on optional setter parameters,
/// distinct from "argument was provided as null". Used by methods that
/// accept partial-update payloads (e.g. `CatalogDao.updateProductDetails`)
/// to map missing args to `Value.absent()` and explicit-null args to
/// `Value(null)` — the latter clears the column, the former leaves it
/// untouched.
const Object _unset = Object();
