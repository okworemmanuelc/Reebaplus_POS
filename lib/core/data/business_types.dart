/// The seven master-plan business types (§1.2), in plan order. Single source of
/// truth for the *display label strings* used in settings and dropdowns.
///
/// DB stores the canonical 'Beer distributor' string for Beverage distributor
/// tenants; Business Info screen maps the display ↔ DB label at load/save time.
/// CEO Sign Up couples each label with an icon and a comingSoon flag in its own
/// private `_businessTypes` record list (ceo_sign_up_screen.dart).
const List<String> kBusinessTypes = [
  'Restaurant',
  'Supermarket',
  'Bar',
  'Beverage distributor',
  'Pharmacy',
  'Building Materials',
  'Boutique',
];

/// Whether [type] is a business that uses empty-crate features — Bar or Beer
/// distributor/Beverage distributor only (master plan §16.10). The single gate
/// for crate-feature visibility; reuse it everywhere instead of re-comparing
/// the raw strings.
///
/// Case-insensitive and trimmed on purpose: businesses onboarded by older
/// builds stored non-canonical casings (e.g. 'Beer Distributor' vs the
/// canonical 'Beverage distributor' above), and an exact-match check silently hid
/// the Empty Crates tab from those tenants. Normalising here keeps the gate
/// correct for that legacy data without a risky migration of synced rows.
bool isCrateBusiness(String? type) {
  final t = type?.trim().toLowerCase();
  return t == 'bar' || t == 'beer distributor' || t == 'beverage distributor';
}

