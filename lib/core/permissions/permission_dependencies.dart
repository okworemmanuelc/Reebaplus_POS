// Permission dependency map (§10.2 gating).
//
// Some permissions only make sense when another permission is held — you can
// only "give a discount" or "cancel" while making a sale, and every
// product/stock-mutation screen is reached through the Inventory screen, which
// is gated by `stock.view`. The CEO's Roles & Permissions screen uses this map
// to (a) disable a child's toggle while its parent is off and (b) cascade-revoke
// a parent's descendants when the parent is turned off.
//
// Each entry is `child : parent`. A child has exactly one parent today; the
// helpers below walk the chain transitively so the behaviour stays correct if
// the map ever deepens. The map was derived from how each permission actually
// gates the app (a true dependency = the child is unreachable or meaningless
// without the parent) and checked against the seeded default roles so that no
// default grant is ever a child without its parent.

/// Child permission key → the parent it depends on.
const Map<String, String> kPermissionParent = {
  // Sales — a cancellation only happens within a sale. (Discounts are governed
  // by the per-role discount slider, not a permission toggle.)
  'sales.cancel': 'sales.make',
  // Products & Stock mutations — all reached only through the Inventory
  // screen, which is gated by `stock.view`.
  'products.add': 'stock.view',
  'products.edit_price': 'stock.view',
  'products.edit_buying_price': 'stock.view',
  'products.delete': 'stock.view',
  'stock.add': 'stock.view',
  'stock.adjust': 'stock.view',
  // Customers — every customer action is meaningless to a role that can't add
  // customers, so `customers.add` is the Customers gate.
  'customers.update': 'customers.add',
  'customers.delete': 'customers.add',
  'customers.wallet.update': 'customers.add',
  'customers.set_debt_limit': 'customers.add',
  'customers.wallet.withdraw': 'customers.add',
  'customers.wallet.totals.view': 'customers.add',
  // Staff — suspend / change-role live inside Staff Management, whose entry is
  // gated by `staff.invite`.
  'staff.suspend': 'staff.invite',
  'staff.change_role': 'staff.invite',
  // Suppliers — incoming shipments come from suppliers.
  'shipments.manage': 'suppliers.manage',
};

/// The direct parent of [key], or null if it has none.
String? parentOf(String key) => kPermissionParent[key];

/// All keys that (transitively) depend on [key] — i.e. everything that must be
/// revoked when [key] is revoked.
Set<String> descendantsOf(String key) {
  final result = <String>{};
  void walk(String parent) {
    for (final entry in kPermissionParent.entries) {
      if (entry.value == parent && result.add(entry.key)) {
        walk(entry.key);
      }
    }
  }

  walk(key);
  return result;
}

/// All keys that [key] (transitively) depends on — i.e. everything that must be
/// granted before [key] can be.
Set<String> ancestorsOf(String key) {
  final result = <String>{};
  var current = kPermissionParent[key];
  while (current != null && result.add(current)) {
    current = kPermissionParent[current];
  }
  return result;
}
