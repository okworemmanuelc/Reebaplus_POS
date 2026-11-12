import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';

void main() {
  group('shouldLockOnResume (#796)', () {
    test('12 hours or more away locks even with auto-lock off', () {
      expect(
        shouldLockOnResume(
          away: const Duration(hours: 12),
          autoLockSeconds: 0,
        ),
        isTrue,
      );
      expect(
        shouldLockOnResume(away: const Duration(days: 3), autoLockSeconds: 0),
        isTrue,
      );
    });

    test('under 12 hours with auto-lock off does nothing', () {
      expect(
        shouldLockOnResume(
          away: const Duration(hours: 11, minutes: 59),
          autoLockSeconds: 0,
        ),
        isFalse,
      );
    });

    test('the chosen auto-lock interval still locks', () {
      expect(
        shouldLockOnResume(
          away: const Duration(seconds: 60),
          autoLockSeconds: 60,
        ),
        isTrue,
      );
      expect(
        shouldLockOnResume(
          away: const Duration(seconds: 59),
          autoLockSeconds: 60,
        ),
        isFalse,
      );
    });
  });
}
