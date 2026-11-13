import 'dart:typed_data';

import 'package:reebaplus_pos/core/utils/share_file_native.dart'
    if (dart.library.js_interop) 'package:reebaplus_pos/core/utils/share_file_web.dart'
    as impl;

/// Hands a finished file to the user: the system share sheet on a phone or
/// tablet, a browser download in the browser (#812; share_plus has no file
/// fallback there). [fileName] includes its extension. [subject] / [text] are
/// only used by the share sheet.
Future<void> shareFileBytes({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  String? subject,
  String? text,
}) => impl.shareFileBytes(
  bytes: bytes,
  fileName: fileName,
  mimeType: mimeType,
  subject: subject,
  text: text,
);
