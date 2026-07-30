import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/shared/services/ui_hint_service.dart';

void main() {
  group('UiHintService', () {
    late UiHintService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = UiHintService();
    });

    test('shouldShow returns true while count < 2 and false at 2', () async {
      const key = UiHintService.hintPosGestures;

      expect(await service.shouldShow(key), true);
      expect(await service.viewCount(key), 0);

      await service.markShown(key);
      expect(await service.shouldShow(key), true);
      expect(await service.viewCount(key), 1);

      await service.markShown(key);
      expect(await service.shouldShow(key), false);
      expect(await service.viewCount(key), 2);
      
      await service.markShown(key);
      expect(await service.shouldShow(key), false);
      expect(await service.viewCount(key), 3);
    });

    test('each screen\'s banner is view-counted independently', () async {
      // Banners on different screens co-exist; retiring one must not consume
      // another's view count (issue #32). POS's two coach tips used to be two
      // keys tested here — they are now the single `hintPosGestures`, because
      // independent retirement across ONE banner is what made a ✕ a
      // half-dismiss (PR #148). Across screens it is still the right rule.
      await service.markShown(UiHintService.hintPosGestures);
      await service.markShown(UiHintService.hintPosGestures);

      expect(await service.shouldShow(UiHintService.hintPosGestures), false);
      expect(await service.shouldShow(UiHintService.hintCartTapEdit), true);
      expect(await service.viewCount(UiHintService.hintCartTapEdit), 0);
      expect(await service.shouldShow(UiHintService.hintReceiveLongpress), true);
    });

    test('a ✕ after one passive view retires the banner — it does NOT come '
        'back once more (PR #148)', () async {
      // The "hint shows double" defect: the screens called `markShown` on the
      // ✕, so a display (0 → 1) plus a dismiss (1 → 2) was needed to retire —
      // meaning a deliberate close on the FIRST visit left the banner showable
      // and it surfaced a second time. `markDismissed` retires outright,
      // whatever the count already is.
      const key = UiHintService.hintPosGestures;
      await service.markShown(key); // the display counts one passive view
      expect(await service.viewCount(key), 1);
      expect(await service.shouldShow(key), true);

      await service.markDismissed(key);
      expect(await service.shouldShow(key), false,
          reason: 'one ✕ is final, regardless of the view count so far');
    });

    test('inventory long-press hint retires permanently on first dismissal '
        '(#110)', () async {
      // AC #3: dismissing the Inventory "press and hold to edit" banner hides
      // it permanently for that staff member — one dismissal is enough, unlike
      // the twice-shown POS banners. Reuses the shared service under its own
      // key.
      expect(await service.shouldShow(UiHintService.hintInventoryLongpress),
          true);

      await service.markDismissed(UiHintService.hintInventoryLongpress);
      expect(await service.shouldShow(UiHintService.hintInventoryLongpress),
          false);

      // The POS key is untouched by the inventory dismissal.
      expect(await service.shouldShow(UiHintService.hintPosGestures), true);
    });

    test('markDismissed retires any hint in a single call', () async {
      // markDismissed is the "permanent" counterpart to the view-counted
      // markShown — one call pushes the stored count to the retire threshold.
      const key = UiHintService.hintPosGestures;
      expect(await service.shouldShow(key), true);

      await service.markDismissed(key);
      expect(await service.shouldShow(key), false);
    });
  });
}
