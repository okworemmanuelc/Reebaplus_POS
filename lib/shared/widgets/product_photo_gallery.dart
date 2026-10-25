import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// A swipeable row of product photos with page dots (#474). One photo shows
/// as a still image with no dots; none shows [placeholder]. Each photo is
/// built by [photoBuilder] (a network or file image), so the gallery itself
/// has no I/O.
class ProductPhotoGallery extends StatefulWidget {
  const ProductPhotoGallery({
    super.key,
    required this.photos,
    required this.photoBuilder,
    required this.placeholder,
    required this.height,
  });

  final List<String> photos;
  final Widget Function(BuildContext context, String photo) photoBuilder;
  final Widget placeholder;
  final double height;

  @override
  State<ProductPhotoGallery> createState() => _ProductPhotoGalleryState();
}

class _ProductPhotoGalleryState extends State<ProductPhotoGallery> {
  int _page = 0;

  @override
  void didUpdateWidget(ProductPhotoGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_page >= widget.photos.length) _page = 0;
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    if (photos.isEmpty) {
      return SizedBox(height: widget.height, child: widget.placeholder);
    }
    if (photos.length == 1) {
      return SizedBox(
        height: widget.height,
        width: double.infinity,
        child: widget.photoBuilder(context, photos.first),
      );
    }
    final t = Theme.of(context);
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          PageView.builder(
            key: const Key('product-photo-gallery'),
            itemCount: photos.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => Semantics(
              label: 'Photo ${i + 1} of ${photos.length}',
              image: true,
              child: SizedBox.expand(
                child: widget.photoBuilder(context, photos[i]),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: context.getRSize(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < photos.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: EdgeInsets.symmetric(horizontal: context.getRSize(3)),
                    width: context.getRSize(i == _page ? 18 : 8),
                    height: context.getRSize(8),
                    decoration: BoxDecoration(
                      color: i == _page
                          ? t.colorScheme.primary
                          : t.colorScheme.surface.withValues(alpha: 0.85),
                      borderRadius:
                          BorderRadius.circular(AppSpacing.borderRadiusL),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
