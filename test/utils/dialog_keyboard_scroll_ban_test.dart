// Static enforcement seam. A source scan that bans pop-ups (AlertDialog /
// Dialog) holding a text box unless their content can scroll.
//
// With the keyboard open a pop-up gets roughly half the screen. An
// AlertDialog's content does not scroll by default, so a text box at the
// bottom gets squeezed ("BOTTOM OVERFLOWED BY 12 PIXELS" on the Orders refund
// pop-up, owner phone check on PR #402). Fix: `scrollable: true` on the
// AlertDialog, or wrap a Dialog's body in a SingleChildScrollView.
//
// Prior art: test/utils/media_query_size_ban_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `AlertDialog(` or a bare `Dialog(` (not SimpleDialog / AlertDialog).
final _dialogStart = RegExp(r'(?<![A-Za-z0-9_])(?:Alert)?Dialog\(');

/// Widgets that open the keyboard.
const _textBoxes = ['AppInput(', 'TextField(', 'TextFormField('];

/// Any of these inside the pop-up means its content can scroll.
const _scrolls = ['scrollable: true', 'SingleChildScrollView(', 'ListView'];

/// Returns the line number of every pop-up in [source] that holds a text
/// box and cannot scroll.
List<int> unscrollableTextDialogs(String source) {
  final hits = <int>[];
  for (final m in _dialogStart.allMatches(source)) {
    var i = m.end;
    var depth = 1;
    while (depth > 0 && i < source.length) {
      final c = source[i];
      if (c == '(') depth++;
      if (c == ')') depth--;
      i++;
    }
    final span = source.substring(m.start, i);
    if (!_textBoxes.any(span.contains)) continue;
    if (_scrolls.any(span.contains)) continue;
    hits.add('\n'.allMatches(source.substring(0, m.start)).length + 1);
  }
  return hits;
}

void main() {
  test('scanner: flags a text-box pop-up that cannot scroll', () {
    expect(
      unscrollableTextDialogs(
        'x(() => AlertDialog(content: Column(children: [AppInput()])));',
      ),
      [1],
    );
    expect(
      unscrollableTextDialogs(
        'x(() => Dialog(child: Column(children: [TextField()])));',
      ),
      [1],
    );
  });

  test('scanner: passes scrollable pop-ups and pop-ups without text boxes', () {
    expect(
      unscrollableTextDialogs(
        'AlertDialog(scrollable: true, content: Column(children: '
        '[AppInput()]));',
      ),
      isEmpty,
    );
    expect(
      unscrollableTextDialogs(
        'Dialog(child: SingleChildScrollView(child: TextField()));',
      ),
      isEmpty,
    );
    expect(
      unscrollableTextDialogs('AlertDialog(content: Text("Sure?"));'),
      isEmpty,
    );
    expect(
      unscrollableTextDialogs('SimpleDialog(children: [TextField()]);'),
      isEmpty,
    );
  });

  test('every pop-up in lib/ with a text box can scroll above the keyboard '
      '(AlertDialog: scrollable: true; Dialog: SingleChildScrollView)', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      for (final line in unscrollableTextDialogs(entity.readAsStringSync())) {
        offenders.add('$path:$line');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'These pop-ups hold a text box but cannot scroll, so the keyboard '
          'squeezes them into an overflow. Add `scrollable: true` to the '
          'AlertDialog (or wrap the Dialog body in a '
          'SingleChildScrollView):\n${offenders.join('\n')}',
    );
  });
}
