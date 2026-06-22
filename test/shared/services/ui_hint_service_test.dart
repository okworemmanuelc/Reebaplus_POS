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
  });
}
