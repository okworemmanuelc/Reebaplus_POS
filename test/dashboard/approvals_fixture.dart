// Shared sample data for the Stock Approvals tests and goldens (#413 PR 3).
// Sample data only; every date is fixed so a golden never depends on the clock.

import 'package:reebaplus_pos/core/database/app_database.dart';

import '../helpers/screen_harness.dart';

final DateTime kApprovalDay = DateTime(2026, 7, 14, 10, 30);

StockAdjustmentRequestData approvalStockReq(
  ScreenTestEnvironment env, {
  String id = 'req-stock-1',
  int diff = 5,
}) => StockAdjustmentRequestData(
  id: id,
  businessId: env.businessId,
  productId: env.products.first.id,
  storeId: env.storeId,
  quantityDiff: diff,
  reason: 'Restock overflow',
  summary:
      '${diff < 0 ? 'Remove' : 'Add'} ${diff.abs()} ${env.products.first.name}',
  requestedBy: 'test-user-id',
  status: 'pending',
  approvedBy: null,
  approvedAt: null,
  createdAt: kApprovalDay,
  lastUpdatedAt: kApprovalDay,
);

QuickSaleRequestData approvalQuickReq(
  ScreenTestEnvironment env, {
  String id = 'req-quick-1',
}) => QuickSaleRequestData(
  id: id,
  businessId: env.businessId,
  storeId: env.storeId,
  itemName: 'Ice Bag',
  quantity: 2,
  unitPriceKobo: 50000,
  summary: 'Quick Sale · Ice Bag',
  requestedBy: 'test-user-id',
  status: 'pending',
  approvedBy: null,
  approvedAt: null,
  createdAt: kApprovalDay,
  lastUpdatedAt: kApprovalDay,
);

SupplierCrateDepositRequestData approvalCrateReq(
  ScreenTestEnvironment env, {
  String id = 'req-crate-1',
  String kind = 'placement',
}) => SupplierCrateDepositRequestData(
  id: id,
  businessId: env.businessId,
  supplierId: 'supplier-1',
  manufacturerId: env.manufacturers.first.id,
  storeId: env.storeId,
  kind: kind,
  crateCount: 10,
  ratePerCrateKobo: 100000,
  requestedAmountKobo: 1000000,
  settledAmountKobo: null,
  paymentMethod: null,
  summary: '10 crates deposit',
  supplierCrateLedgerId: null,
  note: null,
  requestedBy: null,
  status: 'pending',
  decidedBy: null,
  decidedAt: null,
  decisionNote: null,
  createdAt: kApprovalDay,
  lastUpdatedAt: kApprovalDay,
);
