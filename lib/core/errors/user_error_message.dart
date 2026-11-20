import 'dart:convert';

import 'package:reebaplus_pos/shared/utils/quantity.dart';

/// #836 — turns any raised error into a short, plain sentence for shop staff:
/// what is wrong and what to do. Never shows class names, ids, `pg_` / SQL
/// codes or stack text. Log the raw error separately for support.
///
/// [action] completes "Something went wrong while <action>." for unknown
/// errors (e.g. `'completing the sale'`). [productName] resolves a product id
/// (from the server hint) to its name; when null or unresolved the message
/// says "one of the items".
String userErrorMessage(
  Object error, {
  String action = 'doing that',
  String? Function(String productId)? productName,
}) {
  final raw = error.toString();
  final text = raw.toLowerCase();

  bool has(String s) => text.contains(s);

  if (has('insufficient_stock') || has('insufficientstock')) {
    return _stock(raw, productName);
  }
  if (has('inventory_row_missing')) {
    return 'One of the items is not stocked in this store. '
        'Pull down to refresh stock, or receive the stock first, then try again.';
  }
  if (has('insufficient_wallet_balance')) {
    return "The customer's wallet does not have enough money for this sale. "
        'Take another payment method or top up the wallet, then try again.';
  }
  if (has('customer_wallet_missing')) {
    return "This customer's wallet is not set up yet. "
        'Pull down to refresh, then try again.';
  }
  if (has('debt_limit_exceeded')) {
    return "This sale would take the customer over their credit limit. "
        'Collect some payment or lower the amount on credit.';
  }
  if (has('credit_requires_customer') ||
      has('wallet_payment_requires_customer') ||
      has('crate_deposit_requires_customer')) {
    return 'Pick a customer for this sale first, then try again.';
  }
  if (has('amount_paid_below_net')) {
    return 'The amount paid is less than the sale total. '
        'Check the payment and try again.';
  }
  if (has('crate_deposit_exceeds_paid')) {
    return 'The crate deposit is more than the amount paid. '
        'Check the payment and try again.';
  }
  if (has('insufficient_crates')) {
    return 'There are not enough empty crates for this. '
        'Check the crate count and try again.';
  }
  if (has('order_not_found')) {
    return 'This sale could not be found. Pull down to refresh, then try again.';
  }
  if (has('cannot_cancel_status_') || has('cannot_approve_status_')) {
    return 'This has already been dealt with, so it cannot be changed again. '
        'Pull down to refresh to see its latest state.';
  }
  if (has('request_not_found') || has('pending_return_not_found')) {
    return 'This request is no longer there. Pull down to refresh.';
  }
  if (has('permission_denied') ||
      has('42501') ||
      has('insufficient_privilege') ||
      has('row-level security')) {
    return 'You do not have permission to do this. '
        'Ask the owner or a manager to do it or to give you access.';
  }
  if (has('tenant_mismatch')) {
    return 'This does not belong to the shop you are signed in to. '
        'Sign out and sign in again, then try again.';
  }
  if (has('23505') || has('duplicate key') || has('already exists')) {
    return 'This has already been saved. Pull down to refresh to see it.';
  }
  if (has('23503') || has('foreign key')) {
    return 'Something this depends on is missing or was removed. '
        'Pull down to refresh, then try again.';
  }
  if (has('socketexception') ||
      has('failed host lookup') ||
      has('clientexception') ||
      has('timeoutexception') ||
      has('connection closed') ||
      has('connection refused') ||
      has('network is unreachable')) {
    return 'There is no internet connection right now. '
        'Check your connection and try again.';
  }
  if (has('jwt expired') ||
      has('session expired') ||
      has('session_expired') ||
      has('not authenticated') ||
      has('invalid refresh token') ||
      has('authexception') ||
      has('authapiexception')) {
    return 'Your session has expired. Sign in again, then try again.';
  }
  return 'Something went wrong while $action. Please try again. '
      'If it keeps happening, contact support.';
}

String _stock(String raw, String? Function(String productId)? productName) {
  final hint = _parseHint(raw);
  final id = hint?['product_id'];
  final name = id is String ? productName?.call(id) : null;
  final label = (name == null || name.trim().isEmpty)
      ? 'one of the items'
      : name.trim();
  final asked = hint?['requested_qty'];
  final left = hint?['available_qty'];
  final detail = (asked is num && left is num)
      ? ' (cart has ${formatQty(asked)}, only ${formatQty(left)} left)'
      : '';
  return 'Not enough stock for $label$detail. '
      'Pull down to refresh stock, then try again.';
}

Map<String, dynamic>? _parseHint(String raw) {
  final m = RegExp(
    r'hint[=:]\s*(\{[^{}]*\})',
    caseSensitive: false,
  ).firstMatch(raw);
  if (m == null) return null;
  try {
    final j = jsonDecode(m.group(1)!);
    return j is Map<String, dynamic> ? j : null;
  } catch (_) {
    return null;
  }
}
