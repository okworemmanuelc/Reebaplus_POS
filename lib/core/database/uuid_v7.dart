import 'package:uuid/uuid.dart';

class UuidV7 {
  UuidV7._();
  static const _uuid = Uuid();
  static String generate() => _uuid.v7();
}
