import 'package:reebaplus_pos/core/services/barcode_suggestion.dart';

/// How a shared barcode catalogue lookup ended (ADR 0029, #335). Unlike the
/// quiet `BarcodeCatalogueService.lookup`, the report sheet must tell "nothing
/// is shared" apart from "couldn't reach the server".
sealed class CatalogueLookup {
  const CatalogueLookup();
}

/// The catalogue has something for the code. At least one of name, unit,
/// photo bytes or photo URL is set.
final class CatalogueFound extends CatalogueLookup {
  const CatalogueFound(this.suggestion);

  final BarcodeSuggestion suggestion;
}

/// Nothing is shared for the code right now: not a factory GTIN, zero rows,
/// or the kill switch is off.
final class CatalogueNothingShared extends CatalogueLookup {
  const CatalogueNothingShared();
}

/// The server couldn't be reached: offline, no route, or the timeout passed.
final class CatalogueUnreachable extends CatalogueLookup {
  const CatalogueUnreachable();
}

/// The server answered with an error.
final class CatalogueLookupFailed extends CatalogueLookup {
  const CatalogueLookupFailed();
}
