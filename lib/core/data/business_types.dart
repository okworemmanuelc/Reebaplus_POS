import 'package:reebaplus_pos/core/industry/industry.dart';

/// Compatibility shim over the one Industry registry (ADR 0015, #77). The
/// industry facts — labels, icons, coming-soon, crate-eligibility — now live
/// only in [Industry]; this file derives the old public names from it so
/// existing callers keep working without a second copy of the list.
export 'package:reebaplus_pos/core/industry/industry.dart' show isCrateBusiness;

/// The business-type display labels shown in settings/dropdowns, in plan order.
/// Derived from [Industry.catalogue] — no longer a hand-maintained list, so it
/// cannot drift from the registry. DB stores the canonical 'Beer distributor'
/// string for Beverage distributor tenants; the Business Info screen maps the
/// display ↔ DB label at load/save time.
List<String> get kBusinessTypes =>
    Industry.catalogue.map((i) => i.label).toList(growable: false);
