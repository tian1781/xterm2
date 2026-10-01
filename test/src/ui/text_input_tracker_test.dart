import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/src/ui/text_input_tracker.dart';

import '../../_fixture/fake_input_method.dart';

const _twoSpaces = TextEditingValue(
  text: '  ',
  selection: TextSelection.collapsed(offset: 2),
);

/// A tracker and a fake keyboard, and what the terminal received, with each
/// Backspace written as DEL.
class _Session {
  _Session([TextEditingValue initial = _twoSpaces])
      : tracker = TextInputTracker(initial),
        keyboard = FakeInputMethod(initial);

  final TextInputTracker tracker;
  final FakeInputMethod keyboard;
  final received = StringBuffer();

  /// Reports one platform update holding [batch] and returns what the
  /// terminal received for it.
  String send(List<Map<String, dynamic>> batch) {
    final edits = tracker.applyDeltas(
      [for (final encoded in batch) TextEditingDelta.fromJSON(encoded)],
    );
    final bytes = _bytes(edits);
    received.write(bytes);
    return bytes;
  }

  /// Puts the platform's text back as the text edit would, when the tracker
  /// asks for it.
  void resetIfWanted() {
    if (!tracker.wantsReset) return;
    tracker.reset();
    keyboard.value = tracker.value;
  }
}

String _bytes(List<TextInputEdit> edits) => [
      for (final edit in edits) '${'\x7f' * edit.backspaces}${edit.text}',
    ].join();

void main() {
  group('TextInputTracker', () {
    test('sends each typed character', () {
      final session = _Session();

      expect(session.send([session.keyboard.type('D')]), 'D');
      expect(session.send([session.keyboard.type('a')]), 'a');
      expect(session.tracker.wantsReset, isFalse);
    });

    test('takes a deleted character back with one Backspace', () {
      final session = _Session();
      session.send([session.keyboard.type('a')]);
      session.send([session.keyboard.type('b')]);

      expect(session.send([session.keyboard.backspace()]), '\x7f');
      expect(session.tracker.value.text, '  a');
    });

    test(
        'sends Backspace when nothing has been typed, then wants the two '
        'spaces back', () {
      final session = _Session();

      expect(session.send([session.keyboard.backspace()]), '\x7f');
      expect(session.tracker.wantsReset, isTrue);

      session.resetIfWanted();
      expect(session.tracker.value, _twoSpaces);
      expect(session.send([session.keyboard.backspace()]), '\x7f');
    });

    test('wants the two spaces back when the keyboard deletes both at once',
        () {
      // iOS deletes whole words when Backspace is held down.
      final session = _Session();

      expect(session.send([session.keyboard.replace(0, 2, '')]), '\x7f\x7f');
      expect(session.tracker.value.text, isEmpty);
      expect(session.tracker.wantsReset, isTrue);
    });

    test('sends pasted text in one piece', () {
      final session = _Session();

      final edits = session.tracker.applyDeltas([
        TextEditingDelta.fromJSON(session.keyboard.type('echo hello')),
      ]);

      expect(edits, [const TextInputEdit(0, 'echo hello')]);
    });

    test('a suggestion that completes the typed word sends what it adds', () {
      // iOS: typing "Da", then picking "Dad" replaces the word and adds a
      // space, in one update.
      final session = _Session();
      session.send([session.keyboard.type('D')]);
      session.send([session.keyboard.type('a')]);

      final edits = session.tracker.applyDeltas([
        TextEditingDelta.fromJSON(session.keyboard.replace(2, 4, 'Dad')),
        TextEditingDelta.fromJSON(session.keyboard.type(' ')),
      ]);

      expect(edits, [const TextInputEdit(0, 'd ')]);
    });

    test('the reported sequence ends as "Dad and "', () {
      final session = _Session();
      session.send([session.keyboard.type('D')]);
      session.send([session.keyboard.type('a')]);
      session.send([
        session.keyboard.replace(2, 4, 'Dad'),
        session.keyboard.type(' '),
      ]);
      session.resetIfWanted();
      // The next suggestion, "and", is typed with its space.
      session.send([session.keyboard.type('and ')]);
      session.resetIfWanted();

      expect(session.received.toString(), 'Dad and ');
      expect(session.tracker.value, _twoSpaces);
    });

    test('a suggestion that changes typed characters takes them back first',
        () {
      final session = _Session();
      for (final character in 'teh'.split('')) {
        session.send([session.keyboard.type(character)]);
      }

      expect(
          session.send([session.keyboard.replace(2, 5, 'the')]), '\x7f\x7fhe');
      expect(session.received.toString(), 'teh\x7f\x7fhe');
    });

    test('a replacement that reaches into the two spaces takes them back too',
        () {
      final session = _Session();

      expect(
          session.send([session.keyboard.replace(0, 2, 'Dad')]), '\x7f\x7fDad');
    });

    test('counts Backspace presses in code points', () {
      final session = _Session();
      session.send([session.keyboard.type('你')]);
      expect(session.send([session.keyboard.backspace()]), '\x7f');

      session.send([session.keyboard.type('😀')]);
      expect(session.send([session.keyboard.backspace()]), '\x7f');

      // Two emoji that share their first UTF-16 code unit.
      session.send([session.keyboard.type('😀')]);
      expect(session.send([session.keyboard.replace(2, 4, '😃')]), '\x7f😃');
    });

    test('keeps a composition out of the terminal until it is committed', () {
      // Pinyin: "ni" is composed, then "你" replaces it.
      final session = _Session();

      expect(session.send([session.keyboard.compose('n')]), '');
      expect(session.tracker.composingText, 'n');
      expect(session.send([session.keyboard.compose('ni')]), '');
      expect(session.tracker.composingText, 'ni');
      expect(session.tracker.wantsReset, isFalse);

      expect(session.send([session.keyboard.type('你')]), '你');
      expect(session.tracker.composingText, isNull);
    });

    test('sends a composition that ends in place', () {
      // iOS marks the chosen characters and then unmarks them.
      final session = _Session();
      session.send([session.keyboard.compose('ni')]);
      session.send([session.keyboard.compose('你好')]);

      expect(session.send([session.keyboard.finishComposing()]), '你好');
      expect(session.tracker.composingText, isNull);
    });

    test('Android: a composed word goes out with the suggestion and space', () {
      final session = _Session();
      session.send([session.keyboard.compose('D')]);
      session.send([session.keyboard.compose('Da')]);
      expect(session.received.toString(), '');

      expect(
        session.send([
          session.keyboard.type('Dad'),
          session.keyboard.type(' '),
        ]),
        'Dad ',
      );
      expect(session.tracker.wantsReset, isTrue);
    });

    test('deleting inside a composition sends nothing', () {
      final session = _Session();
      session.send([session.keyboard.compose('Da')]);

      expect(session.send([session.keyboard.compose('D')]), '');
      expect(session.send([session.keyboard.compose('')]), '');
      expect(session.tracker.composingText, isNull);
      expect(session.received.toString(), '');
    });

    test('composing a received word again leaves it in the terminal', () {
      // Android keyboards mark the word before the cursor as composing again.
      final session = _Session();
      for (final character in 'Dad'.split('')) {
        session.send([session.keyboard.type(character)]);
      }

      expect(session.send([session.keyboard.composeRegion(2, 5)]), '');
      expect(session.tracker.composingText, isNull);

      expect(session.send([session.keyboard.compose('Da')]), '\x7f');
      expect(session.send([session.keyboard.compose('Dax')]), '');
      expect(session.tracker.composingText, 'x');

      expect(session.send([session.keyboard.finishComposing()]), 'x');
      expect(session.received.toString(), 'Dad\x7fx');
    });

    test('waits for a composition inside the text to end', () {
      final session = _Session();
      session.send([session.keyboard.type('ab')]);
      session.keyboard.value = session.keyboard.value.copyWith(
        selection: const TextSelection.collapsed(offset: 3),
      );

      expect(session.send([session.keyboard.compose('x')]), '');
      expect(session.tracker.composingText, 'x');

      // "a" + "x" + "b": the "b" after the cursor is taken back and sent again.
      expect(session.send([session.keyboard.finishComposing()]), '\x7fxb');
    });

    test('wants a reset after a word, not while typing or composing one', () {
      final session = _Session();
      session.send([session.keyboard.type('ls')]);
      expect(session.tracker.wantsReset, isFalse);

      session.send([session.keyboard.compose('a ')]);
      expect(session.tracker.wantsReset, isFalse);

      session.send([session.keyboard.finishComposing()]);
      expect(session.tracker.wantsReset, isTrue);
    });

    test('wants a reset once the text grows too long', () {
      final session = _Session();
      session.send([session.keyboard.type('x' * TextInputTracker.maxLength)]);

      expect(session.tracker.wantsReset, isTrue);
    });

    test('sends what was typed before the platform took a reset', () {
      final session = _Session();
      session.send([session.keyboard.type('a')]);
      session.send([session.keyboard.type(' ')]);
      expect(session.tracker.wantsReset, isTrue);
      session.tracker.reset();
      // The keyboard typed "b" before the reset reached it.

      expect(session.send([session.keyboard.type('b')]), 'b');
      expect(session.tracker.value, _twoSpaces);

      // The keyboard takes the reset.
      session.keyboard.value = session.tracker.value;
      expect(session.send([session.keyboard.type('c')]), 'c');
    });

    test('drops the newline iOS inserts after a newline action', () {
      final session = _Session();
      session.send([session.keyboard.type('ls')]);
      // Enter has been sent for the newline action, then the text is reset;
      // the newline arrives afterwards, made on the old text.
      session.tracker
        ..expectNewlineEcho()
        ..reset();

      expect(session.send([session.keyboard.type('\n')]), '');

      session.keyboard.value = session.tracker.value;
      expect(session.send([session.keyboard.type('x')]), 'x');
      // Only the first newline after the action is dropped.
      expect(session.send([session.keyboard.type('\n')]), '\n');
    });

    test('follows a composition made before the platform took a reset', () {
      final session = _Session();
      session.send([session.keyboard.type('a')]);
      session.send([session.keyboard.type(' ')]);
      session.tracker.reset();
      // Before the reset reached it, the keyboard composed "n" and then
      // committed "你" in its place.

      expect(session.send([session.keyboard.compose('n')]), '');
      expect(session.send([session.keyboard.type('你')]), '你');
      expect(session.received.toString(), 'a 你');
    });

    test('drops the newline also when the text was not reset', () {
      final session = _Session();
      session.tracker.expectNewlineEcho();

      expect(session.send([session.keyboard.type('\n')]), '');
      expect(session.tracker.wantsReset, isTrue);
    });

    test('takes whole values from platforms that do not send deltas', () {
      final tracker = TextInputTracker(_twoSpaces);

      expect(
        tracker.applyValue(
          const TextEditingValue(
            text: '  ab',
            selection: TextSelection.collapsed(offset: 4),
          ),
        ),
        [const TextInputEdit(0, 'ab')],
      );
      expect(
        tracker.applyValue(
          const TextEditingValue(
            text: '  a',
            selection: TextSelection.collapsed(offset: 3),
          ),
        ),
        [const TextInputEdit(1, '')],
      );
      expect(
        tracker.applyValue(
          const TextEditingValue(
            text: '  a中',
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange(start: 3, end: 4),
          ),
        ),
        isEmpty,
      );
      expect(tracker.composingText, '中');
    });

    test('starts from an empty text without the two spaces', () {
      final session = _Session(
        const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
      );

      expect(session.send([session.keyboard.type('a')]), 'a');
      expect(session.send([session.keyboard.backspace()]), '\x7f');
      expect(session.tracker.wantsReset, isFalse);
    });
  });
}
