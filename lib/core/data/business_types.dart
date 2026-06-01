/// The six master-plan business types (§1.2), in plan order. Single source of
/// truth for the *type strings* — these are load-bearing for later crate and
/// barcode gating (e.g. crate features show only for 'Bar' / 'Beer
/// distributor'), so they must match verbatim everywhere they're used.
///
/// CEO Sign Up couples each label with an icon in its own private
/// `_businessTypes` record list (ceo_sign_up_screen.dart) and must stay in
/// sync with this list. CEO Settings > Business Info reads from here directly.
const List<String> kBusinessTypes = [
  'Restaurant',
  'Supermarket',
  'Bar',
  'Beer distributor',
  'Pharmacy',
  'Boutique',
];

/// Whether [type] is a business that uses empty-crate features — Bar or Beer
/// distributor only (master plan §16.10). The single gate for crate-feature
/// visibility; reuse it everywhere instead of re-comparing the raw strings.
///
/// Case-insensitive and trimmed on purpose: businesses onboarded by older
/// builds stored non-canonical casings (e.g. 'Beer Distributor' vs the
/// canonical 'Beer distributor' above), and an exact-match check silently hid
/// the Empty Crates tab from those tenants. Normalising here keeps the gate
/// correct for that legacy data without a risky migration of synced rows.
bool isCrateBusiness(String? type) {
  final t = type?.trim().toLowerCase();
  return t == 'bar' || t == 'beer distributor';
}
