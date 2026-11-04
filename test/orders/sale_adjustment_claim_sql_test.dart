// #732 — the cloud half of "added goods can be returned" lives in SQL and has no
// Dart seam here. These pin the migration's text to the phone's rule, and the
// claim format both sides share. The migration itself runs on the owner's deploy.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/0251_claim_returns_added_goods.sql',
  ).readAsStringSync();
  final original = File(
    'supabase/migrations/0247_sale_adjustments.sql',
  ).readAsStringSync();

  String signature(String text) {
    final start = text.indexOf(
      'CREATE OR REPLACE FUNCTION public.pos_claim_sale_adjustment(',
    );
    return text.substring(start, text.indexOf('RETURNS jsonb', start));
  }

  String body(String text) {
    final start = text.indexOf(
      'CREATE OR REPLACE FUNCTION public.pos_claim_sale_adjustment(',
    );
    final from = text.indexOf(r'AS $$', start);
    return text.substring(from, text.indexOf(r'$$;', from + 5));
  }

  test('same signature as 0247: no new parameter, so no overload', () {
    expect(signature(sql), signature(original));
    expect(sql, isNot(contains('DROP FUNCTION')));
  });

  test('a claim line may be a plus line of an adjustment of this sale', () {
    expect(sql, contains("o.kind = 'adjustment'"));
    expect(sql, contains('o.adjusts_order_id = p_parent_order_id'));
    expect(sql, contains('oi.order_id = p_parent_order_id'));
    expect(sql, contains('oi.quantity > 0'));
  });

  test('everything else is 0247: lock, idempotent retry, refusals, format', () {
    final b = body(sql);
    for (final kept in [
      'FOR UPDATE',
      "'replayed', true",
      "'order_not_returnable'",
      'public.order_reversals',
      "'adjustment_exceeds_returnable'",
      "'bad_adjustment_quantity'",
      "'order_item_not_found' USING ERRCODE = '23503'",
      "l->>'order_item_id'",
      "cl->>'quantity'",
      '_assert_caller_owns_business(p_business_id)',
    ]) {
      expect(b, contains(kept), reason: kept);
    }
    // The only change is the lookup of what was sold.
    final strip = RegExp(
      r'SELECT (oi\.)?quantity INTO v_sold.*?IF NOT FOUND THEN',
      dotAll: true,
    );
    String normal(String s) => s
        .replaceAll(strip, '')
        .replaceAll(RegExp(r'^\s*--.*$', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ');
    expect(normal(b), normal(body(original)));
  });

  test('grants are kept', () {
    expect(sql, contains('FROM PUBLIC, anon'));
    expect(sql, contains('TO authenticated'));
  });
}
