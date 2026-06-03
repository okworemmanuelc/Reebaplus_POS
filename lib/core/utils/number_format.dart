import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/data/currencies.dart';

/// Formats a number with comma separators.
/// Handles negative numbers by prepending the minus sign.
/// e.g. fmtNumber(5000) → '5,000'
/// e.g. fmtNumber(-5000) → '-5,000'
String fmtNumber(num n) {
  final formatter = NumberFormat('#,###', 'en_US');
  return formatter.format(n);
}

/// App-wide active currency symbol. Defaults to Naira and is kept in sync with
/// the CEO-chosen currency (synced `default_currency` setting, Business Info
/// §10.1) by the app-root bridge in main.dart, which calls
/// [setActiveCurrencyCode] whenever the setting changes. `formatCurrency`
/// reads this so every existing money display (29 call sites + both receipts)
/// follows the business currency without threading a symbol through each one.
String _activeCurrencySymbol = kCurrencySymbols[kDefaultCurrency]!;

/// The active currency symbol (e.g. '₦', r'$', '£', 'GH₵').
String get activeCurrencySymbol => _activeCurrencySymbol;

/// Set the active currency from an ISO-4217 code (e.g. 'NGN', 'USD').
/// Called by the app root when the synced currency setting changes.
void setActiveCurrencyCode(String? code) {
  _activeCurrencySymbol = currencySymbolForCode(code);
}

final _trailingLetter = RegExp(r'[A-Za-z]$');

/// Formats a number as currency using the [activeCurrencySymbol].
/// A space is inserted after letter-ending symbols (e.g. 'KES' → 'KSh 5,000')
/// but not after glyphs (e.g. 'NGN' → '₦5,000', 'USD' → r'$5,000').
/// e.g. formatCurrency(5000) → '₦5,000'  (NGN)
/// e.g. formatCurrency(-5000) → '-₦5,000'
String formatCurrency(num n) {
  final isNegative = n < 0;
  final formatter = NumberFormat('#,##0', 'en_US');
  final formatted = formatter.format(n.abs().round());
  final sym = _activeCurrencySymbol;
  final sep = _trailingLetter.hasMatch(sym) ? ' ' : '';
  return isNegative ? '-$sym$sep$formatted' : '$sym$sep$formatted';
}
