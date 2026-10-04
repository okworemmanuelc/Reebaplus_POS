import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/shared/utils/product_icon_helper.dart';

void main() {
  group('product_icon_helper', () {
    test('constants match FontAwesome 11.0.0 codepoints', () {
      expect(kStoredIconBeerMug, 0xf0fc);
      expect(kStoredIconBeerMug, FontAwesomeIcons.beerMugEmpty.codePoint);

      expect(kStoredIconBox, 0xf466);
      expect(kStoredIconBox, FontAwesomeIcons.box.codePoint);

      expect(kStoredIconBolt, 0xf0e7);
      expect(kStoredIconBolt, FontAwesomeIcons.bolt.codePoint);

      expect(kStoredIconWineBottle, 0xf72f);
      expect(kStoredIconWineBottle, FontAwesomeIcons.wineBottle.codePoint);
    });

    test('resolves stored codepoints to AppIcons', () {
      expect(productIconFromCodePoint(kStoredIconBeerMug), AppIcons.beerMug);
      expect(productIconFromCodePoint(kStoredIconBox), AppIcons.box);
      expect(productIconFromCodePoint(kStoredIconBolt), AppIcons.quickSale);
      expect(
        productIconFromCodePoint(kStoredIconWineBottle),
        AppIcons.wineBottle,
      );
    });

    test('resolves null and unknown codepoints to AppIcons.box', () {
      expect(productIconFromCodePoint(null), AppIcons.box);
      expect(productIconFromCodePoint(0), AppIcons.box);
      expect(productIconFromCodePoint(999999), AppIcons.box);
      expect(productIconFromCodePoint(-1), AppIcons.box);
    });

    test('Quick Sale line stores 0xf0e7 and renders AppIcons.quickSale', () {
      expect(kStoredIconBolt, 0xf0e7);

      final quickSaleLine = <String, dynamic>{
        'name': 'Custom Item',
        'subtitle': 'Quick Sale',
        'price': 500.0,
        'icon': kStoredIconBolt,
        'color': null,
        'category': 'Other',
      };

      expect(quickSaleLine['icon'], 0xf0e7);
      expect(
        productIconFromCodePoint(quickSaleLine['icon'] as int),
        AppIcons.quickSale,
      );
    });
  });
}
