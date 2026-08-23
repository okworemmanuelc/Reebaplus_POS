import 'dart:async';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';

/// Keeps the live cart's crate configuration in step with the catalogue.
///
/// A cart line snapshots its crate fields (`emptyCrateValueKobo`,
/// `trackEmpties`, `unit`, `manufacturerId`) when the product is tapped in.
/// All of those stay editable while the cart is open — the brand deposit rate
/// on the manufacturer, the unit and the track-empties toggle on the product —
/// so the snapshot drifts. The write side never trusted it: `createOrder`
/// re-reads the product and `manufacturers.depositAmountKobo` when it books the
/// crate ledger, so a stale line makes the cart quote one deposit and the sale
/// book another.
///
/// This is the one place that closes that gap, and it closes it by
/// reconciliation rather than by asking every caller to remember a refresh:
/// once [start] is called the service follows the cart's product set with a
/// live query and re-stamps the lines whenever `products` or `manufacturers` is
/// written. The cart screen is mounted once for the whole session (it lives in
/// the main layout's tab stack), so a mount-time read would never see an edit
/// made on the Inventory tab and navigated back from.
class CartCrateSync {
  final AppDatabase _db;
  final CartService _cart;

  StreamSubscription<Map<String, CartCrateConfig>>? _sub;

  /// The product-id set the current [_sub] is watching. Kept so a cart change
  /// that leaves the set alone (a qty tap, a discount) does not churn the
  /// subscription.
  List<String> _watchedIds = const [];

  bool _started = false;

  CartCrateSync(this._db, this._cart);

  /// Begins following the cart. Idempotent — calling it from more than one
  /// screen's `initState` is safe and starts a single subscription.
  void start() {
    if (_started) return;
    _started = true;
    _cart.addListener(_onCartChanged);
    _onCartChanged();
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    _cart.removeListener(_onCartChanged);
    _sub?.cancel();
    _sub = null;
    _watchedIds = const [];
  }

  void _onCartChanged() {
    final ids = _cart.activeProductIds..sort();
    if (_sameIds(ids, _watchedIds)) return;
    _watchedIds = ids;
    _sub?.cancel();
    _sub = null;
    if (ids.isEmpty) return;
    // A logged-out / unbound session has no business to scope the query to;
    // there is also no cart worth reconciling, so drop the attempt rather than
    // letting the StateError escape into a stream with no error handler.
    try {
      _sub = _db.catalogDao
          .watchCrateConfig(ids)
          .listen(_cart.syncCrateConfig);
    } on StateError {
      _watchedIds = const [];
    }
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// One-shot reconcile, awaited before a checkout quote is built. The live
  /// subscription above already keeps the cart fresh; this closes the last
  /// window — an edit committed in the same frame as the Checkout tap, before
  /// the stream has delivered.
  ///
  /// Returns true when a value actually moved, so the caller can re-quote
  /// instead of proceeding on figures the cashier never saw.
  Future<bool> sync() async {
    final productIds = _cart.activeProductIds;
    if (productIds.isEmpty) return false;
    final config = await _db.catalogDao.resolveCrateConfig(productIds);
    return _cart.syncCrateConfig(config);
  }
}
