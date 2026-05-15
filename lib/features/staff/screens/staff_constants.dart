import 'package:flutter/material.dart';

// ── Role config ──────────────────────────────────────────────────────────────
const roleOptions = [
  RoleOption('CEO',          'ceo',          6, Color(0xFFFEF08A)),
  RoleOption('Manager',      'manager',      5, Color(0xFFA855F7)),
  RoleOption('Stock Keeper', 'stock_keeper', 4, Color(0xFF34D399)),
  RoleOption('Cashier',      'cashier',      3, Color(0xFF3B82F6)),
  RoleOption('Rider',        'rider',        2, Color(0xFFF97316)),
];

class RoleOption {
  final String label;
  final String value;
  final int tier;
  final Color color;
  const RoleOption(this.label, this.value, this.tier, this.color);
}

RoleOption roleFor(String role) =>
    roleOptions.firstWhere((r) => r.value == role.toLowerCase(),
        orElse: () => roleOptions.last);
