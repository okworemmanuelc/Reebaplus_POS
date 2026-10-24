final _letterRegExp = RegExp(r'^\p{L}$', unicode: true);
final _digitRegExp = RegExp(r'\d');

/// Normalises an input string into name case:
/// - Trims leading and trailing whitespace, and squashes repeated spaces into one.
/// - In each word, the first letter is capitalised and the rest are lowercase ("sTAR" → "Star").
/// - Capitalises after a hyphen ("coca-cola" → "Coca-Cola") and after an opening bracket ("(big)" → "(Big)").
/// - Does not capitalise after an apostrophe ("mama's" → "Mama's").
/// - Any word containing a digit stays exactly as typed (e.g. "50cl", "1.5L", "7UP", "A14").
/// - Empty input gives empty output (""). Never returns null.
/// - Idempotent: running it twice produces the same result as running it once.
String toNameCase(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return '';

  final words = trimmed.split(RegExp(r'\s+'));
  final buffer = StringBuffer();

  for (var w = 0; w < words.length; w++) {
    if (w > 0) buffer.write(' ');
    final word = words[w];
    if (_digitRegExp.hasMatch(word)) {
      buffer.write(word);
    } else {
      buffer.write(_caseWord(word));
    }
  }

  return buffer.toString();
}

String _caseWord(String word) {
  final out = StringBuffer();
  var capitalizeNext = true;
  var hasSeenLetter = false;

  for (var i = 0; i < word.length; i++) {
    final char = word[i];
    if (char == '-' || char == '–' || char == '—' || char == '‑') {
      out.write(char);
      capitalizeNext = true;
    } else if (char == '(' || char == '[' || char == '{' || char == '<') {
      out.write(char);
      capitalizeNext = true;
    } else if (char == '\'' || char == '’' || char == '‘') {
      out.write(char);
      if (hasSeenLetter) {
        capitalizeNext = false;
      }
    } else if (_letterRegExp.hasMatch(char)) {
      if (capitalizeNext) {
        out.write(char.toUpperCase());
        capitalizeNext = false;
      } else {
        out.write(char.toLowerCase());
      }
      hasSeenLetter = true;
    } else {
      out.write(char);
    }
  }

  return out.toString();
}
