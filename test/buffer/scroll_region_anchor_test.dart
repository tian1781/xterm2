import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// Number of buffer lines whose anchors are still attached.
///
/// A detached line invalidates every [CellAnchor] into it, and
/// `TerminalController.selection` returns null when either endpoint is
/// detached — so detaching live lines silently breaks text selection.
int attachedLineCount(Terminal terminal) {
  final lines = terminal.buffer.lines;
  var attached = 0;
  for (var y = 0; y < lines.length; y++) {
    final anchor = terminal.buffer.createAnchorFromOffset(CellOffset(0, y));
    if (anchor.attached) attached++;
    anchor.dispose();
  }
  return attached;
}

void main() {
  group('scrolling must not detach the lines it moves', () {
    test('alt buffer keeps its lines attached after scrolling', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 20);
      terminal.write('\x1b[?1049h');
      for (var i = 0; i < 24; i++) {
        terminal.write('line-$i\r\n');
      }

      expect(
        attachedLineCount(terminal),
        terminal.buffer.lines.length,
        reason: 'the alt buffer always takes the non-push scroll path, so a '
            'single scroll used to detach every line it moved',
      );
    });

    test('main buffer keeps its lines attached after scrolling in a '
        'DECSTBM region', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 20);
      for (var i = 0; i < 30; i++) {
        terminal.write('pre-$i\r\n');
      }

      terminal.write('\x1b[3;18r'); // DECSTBM: scroll region rows 3..18
      terminal.write('\x1b[18;1H');
      for (var i = 0; i < 25; i++) {
        terminal.write('in-$i\r\n');
      }

      expect(
        attachedLineCount(terminal),
        terminal.buffer.lines.length,
        reason: 'margins disable the push fast path, so the main buffer hit '
            'the same bug — programs with a status line (apt progress bars, '
            'fzf --height) left the scrollback unselectable',
      );
    });

    test('selection survives a scroll in the alt buffer', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 20);
      terminal.write('\x1b[?1049h');
      for (var i = 0; i < 24; i++) {
        terminal.write('line-$i\r\n');
      }

      final controller = TerminalController();
      addTearDown(controller.dispose);
      controller.setSelection(
        terminal.buffer.createAnchorFromOffset(const CellOffset(0, 2)),
        terminal.buffer.createAnchorFromOffset(const CellOffset(6, 4)),
      );

      expect(
        controller.selection,
        isNotNull,
        reason: 'user-visible symptom: text could not be selected at all',
      );
    });

    test('scrolling still moves content correctly', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 5);
      terminal.write('\x1b[?1049h');
      for (var i = 0; i < 8; i++) {
        terminal.write('row-$i\r\n');
      }

      final text = [
        for (var y = 0; y < terminal.buffer.lines.length; y++)
          terminal.buffer.lines[y].getText().trimRight(),
      ].where((line) => line.isNotEmpty).toList();

      expect(text, ['row-4', 'row-5', 'row-6', 'row-7']);
    });
  });
}
