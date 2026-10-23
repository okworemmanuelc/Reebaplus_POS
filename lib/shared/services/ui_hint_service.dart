import 'package:shared_preferences/shared_preferences.dart';

class UiHintService {
  static const hintCartTapEdit = 'hint_cart_tap_edit';
  // Single POS coach banner: "tap to add to the cart, tap and hold to choose the
  // quantity". Replaces the former separate tap-add + long-press banners so POS
  // never stacks two tips. On POS, long-press opens the qty/discount sheet to add
  // several at once — it does NOT edit the product — so the copy says "quantity".
  static const hintPosGestures = 'hint_pos_gestures';
  // Request Stock's one combined coach banner (#380): "tap a product to add it
  // to the request, or tap and hold to choose a quantity". Same retire rules
  // as POS's: view-counted on display, a deliberate ✕ retires it for good.
  static const hintRequestStockGestures = 'hint_request_stock_gestures';

  // A hint stops surfacing once its stored view-count reaches this threshold —
  // whether it got there by repeated views (markShown) or a deliberate
  // dismissal (markDismissed).
  static const _retireAfter = 2;

  Future<int> viewCount(String hintKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(hintKey) ?? 0;
  }

  Future<bool> shouldShow(String hintKey) async {
    final count = await viewCount(hintKey);
    return count < _retireAfter;
  }

  Future<void> markShown(String hintKey) async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(hintKey) ?? 0) + 1;
    await prefs.setInt(hintKey, count);
  }

  /// Permanently retires a hint (e.g. the user dismissed it deliberately),
  /// regardless of how many times it has been shown. Uses the same local store
  /// as [markShown] — no new persistence mechanism.
  Future<void> markDismissed(String hintKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(hintKey, _retireAfter);
  }
}

final uiHintService = UiHintService();
