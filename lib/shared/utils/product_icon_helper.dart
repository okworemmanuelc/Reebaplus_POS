import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// Resolves a product's icon from a database codePoint.
/// Falls back to [FontAwesomeIcons.box] if null or unrecognized.
IconData productIconFromCodePoint(int? codePoint) {
  if (codePoint == null) {
    return FontAwesomeIcons.box.data;
  }

  // Pre-defined mappings for known icon code points to satisfy `@mustBeConst`
  // and ensure compatibility with icon tree shaking.
  if (codePoint == 0xf0fc ||
      codePoint == FontAwesomeIcons.beerMugEmpty.data.codePoint) {
    return FontAwesomeIcons.beerMugEmpty.data;
  }
  if (codePoint == FontAwesomeIcons.box.data.codePoint) {
    return FontAwesomeIcons.box.data;
  }
  // Quick Sale lines (§12.3) carry the bolt codepoint so they render the bolt
  // in the cart/checkout instead of the box fallback.
  if (codePoint == FontAwesomeIcons.bolt.data.codePoint) {
    return FontAwesomeIcons.bolt.data;
  }
  if (codePoint == FontAwesomeIcons.wineBottle.data.codePoint) {
    return FontAwesomeIcons.wineBottle.data;
  }

  // Fallback icon
  return FontAwesomeIcons.box.data;
}
