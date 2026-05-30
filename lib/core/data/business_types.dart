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
