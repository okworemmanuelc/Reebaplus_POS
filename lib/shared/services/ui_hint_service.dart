import 'package:shared_preferences/shared_preferences.dart';

class UiHintService {
  // Bumped to _v2 when the hint changed from a per-item info badge to the
  // inline dismissible banner: users who exhausted the old badge's view count
  // should still see the new banner a couple of times.
  static const hintReceiveLongpress = 'hint_receive_longpress_v2';
  static const hintCartTapEdit = 'hint_cart_tap_edit';
  // Single POS coach banner: "tap to add to the cart, tap and hold to choose the
  // quantity". Replaces the former separate tap-add + long-press banners so POS
  // never stacks two tips. On POS, long-press opens the qty/discount sheet to add
  // several at once — it does NOT edit the product — so the copy says "quantity".
  static const hintPosGestures = 'hint_pos_gestures';
  // Discoverability banner on the Inventory Products list (issue #110): "press
  // and hold a product to edit it". Only surfaced to staff the price-edit gate
  // (Gates.editProductPrice) lets long-press-edit; dismissal is permanent per
  // staff member, stored locally, never synced.
  static const hintInventoryLongpress = 'hint_inventory_longpress';

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
