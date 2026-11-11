import 'package:ai_app/core/term_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('urlAt finds the URL under a column', () {
    const line = 'see https://docs.alcf.anl.gov/services/x. and more';
    expect(urlAt(line, 10), 'https://docs.alcf.anl.gov/services/x');
    expect(urlAt(line, 4), 'https://docs.alcf.anl.gov/services/x');
    expect(urlAt(line, 2), isNull);
    expect(urlAt('(http://a.b/c)', 3), 'http://a.b/c');
    expect(urlAt('no link here', 3), isNull);
  });

  test('findAll is case-insensitive and reports every hit', () {
    final hits = findAll(['Error one', 'ok', 'two errors, ERROR'], 'error');
    expect(hits, [
      const TextHit(0, 0, 5),
      const TextHit(2, 4, 9),
      const TextHit(2, 12, 17),
    ]);
    expect(findAll(['abc'], ''), isEmpty);
  });

  test('zoomed clamps and resets', () {
    expect(zoomed(13.5, 1), 14.5);
    expect(zoomed(13.5, -1), 12.5);
    expect(zoomed(24, 1), 24);
    expect(zoomed(9, -1), 9);
    expect(zoomed(20, 0), kTermFontSize);
  });

  group('cell text', () {
    Terminal term(String out) => Terminal()..write(out);

    test('cells skipped by cursor moves read as spaces', () {
      // ratatui draws "Called codex" as "Called", cursor-forward 1, "codex".
      final t = term('Called\x1b[1Ccodex   ');
      expect(t.buffer.lines[0].getText().trimRight(), 'Calledcodex');
      expect(lineText(t.buffer.lines[0]), 'Called codex');
    });

    test('a wide character keeps its width, no extra space', () {
      final t = term('a日\x1b[1Cb');
      expect(lineText(t.buffer.lines[0]), 'a日 b');
    });

    test('selectionText joins lines, unwrapped ones with newlines', () {
      final t = term('one\x1b[1Ctwo\r\nthree');
      final range = BufferRangeLine(
        CellOffset(0, 0),
        CellOffset(t.viewWidth - 1, 1),
      );
      expect(selectionText(t.buffer, range), 'one two\nthree');
    });
  });
}
