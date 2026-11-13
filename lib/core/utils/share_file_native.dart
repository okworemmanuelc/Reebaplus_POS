import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Phones and tablets: write to the temp folder, open the share sheet.
Future<void> shareFileBytes({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  String? subject,
  String? text,
}) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes);
  await Share.shareXFiles(
    [XFile(file.path, mimeType: mimeType)],
    subject: subject,
    text: text,
  );
}
