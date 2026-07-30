import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

/// Color tag for a role, keyed by its stable slug (master plan §8.2):
/// CEO yellow, Manager blue, Cashier green, Stock keeper grey, Driver grey.
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
    case 'driver':
      return _roleGrey;
    default:
      return _roleGrey;
  }
}

/// Sort rank for a role by its stable slug — CEO first, then Manager,
/// Cashier, Stock keeper, Driver (the master-plan role hierarchy; #140 appends
/// Driver last, spec §10). Unknown / null slugs sort last. Used to arrange
/// staff by role in Staff Management (§9.2) and to order every role picker.
///
/// Mirrored by [GateTier] in `core/permissions/gate.dart` — the two must stay
/// in step or a tier gate means something different from the displayed order.
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
    case 'driver':
      return 4;
    default:
      return 5;
  }
}

const Color _roleGrey = Color(0xFF94A3B8);
