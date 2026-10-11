import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/src/ui/painter.dart';
import 'package:xterm2/xterm.dart';

TerminalPainter _painter() => TerminalPainter(
      theme: TerminalThemes.whiteOnBlack,
      textStyle: const TerminalStyle(fontSize: 14, height: 1),
      textScaler: TextScaler.noScaling,
    );

BufferLine _line(String text) {
  final terminal = Terminal();
  terminal.write(text);
  return terminal.buffer.lines[0];
}

Future<Uint8List> _render(
  TerminalPainter painter,
  BufferLine line, {
  List<int>? mask,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  painter.paintLineForegrounds(canvas, Offset.zero, line, maskRanges: mask);
  final picture = recorder.endRecording();
  final image = await picture.toImage(400, 30);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  test('masked cells paint exactly like literal asterisks', () async {
    final painter = _painter();
    final masked = await _render(
      painter,
      _line('ab1.2.3.4cd'),
      mask: const [2, 9],
    );
    final literal = await _render(painter, _line('ab*******cd'));
    expect(masked, literal);
    painter.dispose();
  });

  test('wide cells are masked with a fullwidth asterisk', () async {
    final painter = _painter();
    final masked = await _render(
      painter,
      _line('x中文y'),
      mask: const [1, 5],
    );
    final literal = await _render(painter, _line('x＊＊y'));
    expect(masked, literal);
    painter.dispose();
  });

  test('several ranges on one line', () async {
    final painter = _painter();
    final masked = await _render(
      painter,
      _line('root@10.0.0.1:~#'),
      mask: const [0, 4, 5, 13],
    );
    final literal = await _render(painter, _line('****@********:~#'));
    expect(masked, literal);
    painter.dispose();
  });

  test('null and empty masks paint the real text', () async {
    final painter = _painter();
    // The test font draws every glyph as a box except `p` (it has a
    // descender), so `p` is what tells a masked cell from a real one.
    final line = _line('pppp');
    final plain = await _render(painter, line);
    expect(await _render(painter, line, mask: const []), plain);
    expect(await _render(painter, line, mask: null), plain);
    final masked = await _render(painter, line, mask: const [0, 4]);
    expect(masked, isNot(plain));
    expect(masked, await _render(painter, _line('****')));
    painter.dispose();
  });

  test('masked cells all share the one asterisk glyph', () async {
    final narrow = _painter();
    await _render(narrow, _line('abc'), mask: const [0, 3]);
    expect(narrow.paragraphCacheLength, 1);
    narrow.dispose();

    final wide = _painter();
    await _render(wide, _line('中文'), mask: const [0, 4]);
    expect(wide.paragraphCacheLength, 1);
    final literal = _painter();
    await _render(literal, _line('＊'));
    await _render(literal, _line('中文'), mask: const [0, 4]);
    expect(literal.paragraphCacheLength, 1);
    wide.dispose();
    literal.dispose();
  });

  test('masking never modifies the buffer line', () async {
    final painter = _painter();
    final line = _line('root@1.2.3.4');
    await _render(painter, line, mask: const [0, 12]);
    expect(line.getText(), 'root@1.2.3.4');
    painter.dispose();
  });

  testWidgets('TerminalView.lineMask is asked for visible lines only',
      (tester) async {
    final terminal = Terminal(maxLines: 1000);
    for (var i = 0; i < 200; i++) {
      terminal.write('line $i\r\n');
    }
    final asked = <BufferLine>{};
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: TerminalView(
          terminal,
          lineMask: (line) {
            asked.add(line);
            return const [0, 4];
          },
        ),
      ),
    );
    expect(asked, isNotEmpty);
    expect(asked.length, lessThan(terminal.buffer.lines.length));
    expect(terminal.buffer.lines[0].getText(), 'line 0');
  });
}
