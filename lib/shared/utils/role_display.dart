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

/// Sort rank for a role by its stable slug — CEO first, then Manager,
/// Cashier, Stock keeper (the master-plan role hierarchy). Unknown / null
/// slugs sort last. Used to arrange staff by role in Staff Management (§9.2).
int roleRank(String? slug) {
  switch (slug) {
    case 'ceo':
      return 0;
    case 'manager':
      return 1;
    case 'cashier':
      return 2;
    case 'stock_keeper':
      return 3;
    default:
      return 4;
  }
}

const Color _roleGrey = Color(0xFF94A3B8);
