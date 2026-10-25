import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/listings/listing_content.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';

/// Offline listing write boundary. Checks the effective grant before touching
/// the DAO; failures leave the switch showing its persisted value.
class ProductListingService {
  const ProductListingService(this._catalog);

  final CatalogDao _catalog;

  Future<Result<void, AppError>> setShowOnline({
    required String productId,
    required bool showOnline,
    required GateContext gateContext,
  }) async {
    if (!Gates.manageListing.evaluate(gateContext)) {
      return Result.err(AppError.permission(
        'You no longer have access to Manage online listings.'));
    }
    try {
      final changed = await _catalog.setProductShowOnline(
        productId: productId, showOnline: showOnline);
      if (!changed) {
        return Result.err(AppError.io('This product is no longer available.'));
      }
      return Result.ok(null);
    } catch (error, stack) {
      CrashReporter.record(error, stack, context: 'inventory.online_listing');
      return Result.err(AppError.io('Could not save online visibility. Try again.'));
    }
  }
  /// Saves the online description, brand and order limits (#473). Rechecks
  /// the grant and the shape (the DB CHECKs are the last line, not the first).
  Future<Result<void, AppError>> saveContent({
    required String productId,
    required ListingContent content,
    required GateContext gateContext,
  }) async {
    if (!Gates.manageListing.evaluate(gateContext)) {
      return Result.err(AppError.permission(
        'You no longer have access to Manage online listings.'));
    }
    final parsed = parseListingContent(
      description: content.onlineDescription ?? '',
      brand: content.brand ?? '',
      minOrder: '${content.minOrderQty}',
      orderStep: '${content.orderStep}',
      maxOrder: content.maxOrderQty == null ? '' : '${content.maxOrderQty}',
    );
    final valid = parsed.content;
    if (valid == null) return Result.err(AppError.io(parsed.message!));
    try {
      final changed = await _catalog.setProductListingContent(
        productId: productId,
        onlineDescription: valid.onlineDescription,
        brand: valid.brand,
        minOrderQty: valid.minOrderQty,
        orderStep: valid.orderStep,
        maxOrderQty: valid.maxOrderQty,
      );
      if (!changed) {
        return Result.err(AppError.io('This product is no longer available.'));
      }
      return Result.ok(null);
    } catch (error, stack) {
      CrashReporter.record(error, stack, context: 'inventory.online_listing');
      return Result.err(AppError.io('Could not save the online listing. Try again.'));
    }
  }
}
