import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Shared CSV export for the Business Reports detail screens (§25.6 / §25.7 —
/// "CSV from day one"). Builds an RFC-4180 CSV string and opens the system share
/// sheet with it as a `.csv` file. No new dependency — reuses the same
/// `path_provider` + `share_plus` pair the receipt share already uses.

/// Quotes a single CSV field when it contains a comma, double-quote, or line
/// break, doubling any embedded quotes (RFC 4180).
String _csvField(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// Joins a [header] row and [rows] into a CSV string (CRLF line endings, the
/// RFC-4180 default that spreadsheet apps open cleanly).
String buildCsv(List<String> header, List<List<String>> rows) {
  final buffer = StringBuffer();
  buffer.write(header.map(_csvField).join(','));
  buffer.write('\r\n');
  for (final row in rows) {
    buffer.write(row.map(_csvField).join(','));
    buffer.write('\r\n');
  }
  return buffer.toString();
}

/// Writes [csv] to a temporary `<fileName>.csv` and opens the share sheet.
/// [fileName] must not include the extension.
Future<void> shareCsv({
  required String csv,
  required String fileName,
  String? subject,
}) async {
  final tempDir = await getTemporaryDirectory();
  final file = File('${tempDir.path}/$fileName.csv');
  await file.writeAsString(csv);
  await Share.shareXFiles(
    [XFile(file.path, mimeType: 'text/csv')],
    subject: subject,
  );
}
