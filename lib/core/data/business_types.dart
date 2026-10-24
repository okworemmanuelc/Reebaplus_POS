import 'package:reebaplus_pos/core/industry/industry.dart';

/// Compatibility shim over the one Industry registry (ADR 0015, #77). The
/// industry facts — labels, icons, coming-soon, crate-eligibility — now live
/// only in [Industry]; this file derives the old public names from it so
/// existing callers keep working without a second copy of the list.
export 'package:reebaplus_pos/core/industry/industry.dart' show isCrateBusiness;

/// All known business-type display labels, in plan order — the full registry
/// via [Industry.catalogue]. Used to VALIDATE / round-trip a stored type on
/// load (so a tenant already on a now-hidden trade keeps its selection), not to
/// populate a picker: pickers OFFER only [kSelectableBusinessTypes] (#112).
/// Derived from the registry so it cannot drift. DB stores the canonical
/// 'Beer distributor' string for Beverage distributor tenants; the Business
/// Info screen maps the display ↔ DB label at load/save time.
final List<String> kBusinessTypes = Industry.catalogue
    .map((i) => i.label)
    .toList(growable: false);

/// Label for the free-typed "Other" business type option in pickers (#492).
const String kOtherBusinessType = 'Other';

/// The business-type labels OFFERED in the onboarding + Settings pickers — all
/// nine shop types from the registry (#492). Derived from
/// [Industry.selectableCatalogue] so it can never drift from the registry.
final List<String> kSelectableBusinessTypes = Industry.selectableCatalogue
    .map((i) => i.label)
    .toList(growable: false);
