import 'package:flutter/widgets.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';

/// Stored FontAwesome codepoints used in database and cart lines.
/// The saved format does not change; we translate them to [AppIcons] on read.
const int kStoredIconBeerMug = 0xf0fc;
const int kStoredIconBox = 0xf466;
const int kStoredIconBolt = 0xf0e7;
const int kStoredIconWineBottle = 0xf72f;

/// Resolves a product's icon from a database codePoint.
/// Falls back to [AppIcons.box] if null or unrecognized.
IconData productIconFromCodePoint(int? codePoint) {
  if (codePoint == null) {
    return AppIcons.box;
  }

  if (codePoint == kStoredIconBeerMug) {
    return AppIcons.beerMug;
  }
  if (codePoint == kStoredIconBox) {
    return AppIcons.box;
  }
  // Quick Sale lines (§12.3) carry the bolt codepoint so they render the bolt
  // in the cart/checkout instead of the box fallback.
  if (codePoint == kStoredIconBolt) {
    return AppIcons.quickSale;
  }
  if (codePoint == kStoredIconWineBottle) {
    return AppIcons.wineBottle;
  }

  // Fallback icon
  return AppIcons.box;
}
