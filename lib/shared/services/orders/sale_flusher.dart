import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

/// Narrow seam (ADR 0004) through which the Order module pushes a just-settled
/// sale to the cloud and learns whether the server permanently rejected it.
///
/// It exists to decouple [OrderCommands] from the concrete Sync Engine: the
/// checkout flush → reject → compensate path is the subtlest thing the module
/// does, and a fake `SaleFlusher` lets it be unit-tested (accept / reject /
/// offline-noop) without standing up the whole `SupabaseSyncService`. Mirrors
/// the Cloud Transport seam pattern (ADR 0001).
///
/// A permanent server rejection surfaces as [SaleSyncException] (still defined
/// on the Sync Engine, which throws it); the module catches it and compensates.
abstract class SaleFlusher {
  /// Whether a *foreground* flush should be attempted (wired + online). When
  /// false, checkout skips the flush and the background drain pushes the queued
  /// sale later — exactly the old `_syncService != null && isOnline` guard.
  bool get canFlush;

  /// Push the just-settled sale [orderId], surfacing a permanent server
  /// rejection as [SaleSyncException]. No-op when offline, when the queue row is
  /// absent (already drained), or on a transient error (stays pending).
  Future<void> flushSale(String orderId);
}

/// Real adapter over the Sync Engine.
class SyncSaleFlusher implements SaleFlusher {
  final SupabaseSyncService _sync;
  const SyncSaleFlusher(this._sync);

  @override
  bool get canFlush => _sync.isOnline.value;

  @override
  Future<void> flushSale(String orderId) => _sync.flushSale(orderId);
}

/// No-op flusher for when the module is constructed without a Sync Engine
/// (unit tests exercising only the local writes). Never flushes.
class NoopSaleFlusher implements SaleFlusher {
  const NoopSaleFlusher();

  @override
  bool get canFlush => false;

  @override
  Future<void> flushSale(String orderId) async {}
}
