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
      const key = UiHintService.hintPosLongpress;

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

    test('POS tap-add and long-press hints are view-counted independently',
        () async {
      // The two POS coach banners can co-exist; dismissing one must not
      // consume the other's view count (issue #32).
      await service.markShown(UiHintService.hintPosTapAdd);
      await service.markShown(UiHintService.hintPosTapAdd);

      expect(await service.shouldShow(UiHintService.hintPosTapAdd), false);
      expect(await service.shouldShow(UiHintService.hintPosLongpress), true);
      expect(await service.viewCount(UiHintService.hintPosLongpress), 0);
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

      // POS keys are untouched by the inventory dismissal.
      expect(await service.shouldShow(UiHintService.hintPosLongpress), true);
      expect(await service.shouldShow(UiHintService.hintPosTapAdd), true);
    });

    test('markDismissed retires any hint in a single call', () async {
      // markDismissed is the "permanent" counterpart to the view-counted
      // markShown — one call pushes the stored count to the retire threshold.
      const key = UiHintService.hintPosLongpress;
      expect(await service.shouldShow(key), true);

      await service.markDismissed(key);
      expect(await service.shouldShow(key), false);
    });
  });
}
