import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

/// Color tag for a role, keyed by its stable slug (master plan §8.2):
/// CEO yellow, Manager blue, Cashier green, Stock keeper grey.
/// Unknown / null slugs fall back to grey.
Color roleTagColor(String? slug) {
  switch (slug) {
    case 'ceo':
      return amberPrimary;
    case 'manager':
      return blueMain;
    case 'cashier':
      return success;
    case 'stock_keeper':
      return _roleGrey;
    default:
      return _roleGrey;
  }
}

const Color _roleGrey = Color(0xFF94A3B8);
