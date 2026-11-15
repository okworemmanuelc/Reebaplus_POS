import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/local_photo_image.dart';

/// Hands [builder] the photo to draw for a product picture (#832): the device
/// copy (or the cloud url in the browser) from [productPhotoPathProvider],
/// else null while loading / when there is no photo, so the site shows its
/// category tint and icon. Every product-picture site goes through this.
class ProductPhotoBuilder extends ConsumerWidget {
  const ProductPhotoBuilder({
    super.key,
    required this.productId,
    required this.imageUrl,
    this.imagePath,
    required this.builder,
  });

  final String productId;
  final String? imageUrl;

  /// A legacy synced `image_path`; only a fallback, never written.
  final String? imagePath;
  final Widget Function(BuildContext context, String? photo) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = ref
        .watch(productPhotoPathProvider((productId, imageUrl)))
        .asData
        ?.value;
    final photo =
        (resolved != null && resolved.isNotEmpty ? resolved : null) ??
        productPhotoRef(imagePath: imagePath, imageUrl: imageUrl);
    return builder(context, photo);
  }
}
