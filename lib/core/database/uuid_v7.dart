import 'package:uuid/uuid.dart';

class UuidV7 {
  UuidV7._();
  static const _uuid = Uuid();
  static String generate() => _uuid.v7();

  /// A DETERMINISTIC UUID (v5) derived from [seed]: the same seed always yields
  /// the same UUID, on every device and every run. Used where independent
  /// devices must mint the SAME id for the same logical row without ever
  /// talking to each other — e.g. the FIFO opening cost-batch each device seeds
  /// locally in the v58 migration (see [CostBatches]); identical ids let the
  /// per-(product, store) opening batch converge via `insertOnConflictUpdate`
  /// instead of duplicating once per device on sync.
  static String deterministic(String seed) =>
      _uuid.v5(Namespace.url.value, seed);
}
