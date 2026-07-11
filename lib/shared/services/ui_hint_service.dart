import 'package:shared_preferences/shared_preferences.dart';

class UiHintService {
  // Bumped to _v2 when the hint changed from a per-item info badge to the
  // inline dismissible banner: users who exhausted the old badge's view count
  // should still see the new banner a couple of times.
  static const hintPosLongpress = 'hint_pos_longpress_v2';
  static const hintReceiveLongpress = 'hint_receive_longpress_v2';
  static const hintCartTapEdit = 'hint_cart_tap_edit';
  // Coach tip for a joining staff member landing on an already-stocked store
  // (issue #32 / ADR 0006): "tap a product to add it to the cart". Only shown
  // when the POS grid actually has products to tap.
  static const hintPosTapAdd = 'hint_pos_tap_add';
  // Discoverability banner on the Inventory Products list (issue #110): "press
  // and hold a product to edit it". Only surfaced to staff the price-edit gate
  // (Gates.editProductPrice) lets long-press-edit; dismissal is permanent per
  // staff member, stored locally, never synced.
  static const hintInventoryLongpress = 'hint_inventory_longpress';

  Future<int> viewCount(String hintKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(hintKey) ?? 0;
  }

  Future<bool> shouldShow(String hintKey) async {
    final count = await viewCount(hintKey);
    return count < 2;
  }

  Future<void> markShown(String hintKey) async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(hintKey) ?? 0) + 1;
    await prefs.setInt(hintKey, count);
  }
}

final uiHintService = UiHintService();
