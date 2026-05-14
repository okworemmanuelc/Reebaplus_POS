// Nigerian mobile-phone validation used by the signup wizard.
// Accepts formats:
//   • 0XXXXXXXXXX        (11 digits, leading 0, second digit 7/8/9)
//   • +234XXXXXXXXXX     (13 chars incl. +)
//   • 234XXXXXXXXXX      (12 digits, no +)
// Returns null on valid, an error string on invalid.

final RegExp _phoneRe = RegExp(r'^(\+?234|0)[7-9]\d{9}$');

/// Validate a required phone field. Empty fails.
String? validatePhoneRequired(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return 'Required';
  if (!_phoneRe.hasMatch(v)) return 'Enter a valid Nigerian phone number';
  return null;
}

/// Validate an optional phone field. Empty passes; non-empty must match.
String? validatePhoneOptional(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return null;
  if (!_phoneRe.hasMatch(v)) return 'Enter a valid Nigerian phone number';
  return null;
}
