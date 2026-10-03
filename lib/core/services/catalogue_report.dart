/// What a shop can report about a shared barcode catalogue entry (ADR 0029
/// §6, #335). [wire] is the value `report_barcode_catalogue_entry` accepts.
enum CatalogueReportReason {
  wrongName('wrong_name'),
  wrongUnit('wrong_unit'),
  badPhoto('bad_photo');

  const CatalogueReportReason(this.wire);

  final String wire;
}

/// How sending a report ended. Nothing is queued on the phone, so a caller
/// shows [CatalogueReportOffline] and lets the person send again later.
sealed class CatalogueReportResult {
  const CatalogueReportResult();
}

/// The server stored (or updated) the report.
final class CatalogueReportSent extends CatalogueReportResult {
  const CatalogueReportSent();
}

/// The server couldn't be reached: offline, no route, or the timeout passed.
final class CatalogueReportOffline extends CatalogueReportResult {
  const CatalogueReportOffline();
}

/// The server answered with an error (not a member, bad input, a fault).
final class CatalogueReportFailed extends CatalogueReportResult {
  const CatalogueReportFailed();
}
