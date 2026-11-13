import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

/// What a photo widget should be given for a product (#812): on a phone the
/// on-device copy ([imagePath]); in the browser, which keeps no photo files,
/// the cloud [imageUrl] (null when the product has no photo).
String? productPhotoRef({String? imagePath, String? imageUrl}) {
  if (!kIsWeb) return imagePath;
  final url = (imageUrl ?? '').trim();
  return url.isEmpty ? null : url;
}

/// True when [ref] is a web address rather than a file path.
bool isPhotoUrl(String ref) =>
    ref.startsWith('http://') || ref.startsWith('https://');

/// Whether [ref] can be drawn now: a web address always can (the browser
/// fetches it), a file path only where files exist and the file is there.
bool photoRefExists(String? ref) {
  if (ref == null || ref.isEmpty) return false;
  if (isPhotoUrl(ref)) return true;
  if (kIsWeb) return false;
  return File(ref).existsSync();
}

/// The [ImageProvider] for a photo [ref] (see [photoRefExists]).
ImageProvider photoRefProvider(String ref) =>
    isPhotoUrl(ref) ? NetworkImage(ref) : FileImage(File(ref));

/// `Image.file` that also works in the browser (#812): a web address renders
/// with `Image.network`, a bare file path (which the browser cannot read)
/// falls back to [errorBuilder].
class LocalPhotoImage extends StatelessWidget {
  const LocalPhotoImage(
    this.ref, {
    super.key,
    this.fit,
    this.width,
    this.height,
    this.errorBuilder,
  });

  final String ref;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) {
    if (isPhotoUrl(ref)) {
      return Image.network(
        ref,
        fit: fit,
        width: width,
        height: height,
        errorBuilder: errorBuilder,
      );
    }
    if (kIsWeb) {
      return errorBuilder?.call(context, 'no file access', null) ??
          const SizedBox.shrink();
    }
    return Image.file(
      File(ref),
      fit: fit,
      width: width,
      height: height,
      errorBuilder: errorBuilder,
    );
  }
}
