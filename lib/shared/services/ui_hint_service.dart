import 'package:shared_preferences/shared_preferences.dart';

class UiHintService {
  // Bumped to _v2 when the hint changed from a per-item info badge to the
  // inline dismissible banner: users who exhausted the old badge's view count
  // should still see the new banner a couple of times.
  static const hintPosLongpress = 'hint_pos_longpress_v2';
  static const hintReceiveLongpress = 'hint_receive_longpress_v2';
  static const hintCartTapEdit = 'hint_cart_tap_edit';

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
