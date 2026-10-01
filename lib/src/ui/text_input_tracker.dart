import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the terminal has to receive for one change made by the input method:
/// [backspaces] presses of Backspace, then [text].
@immutable
class TextInputEdit {
  const TextInputEdit(this.backspaces, this.text);

  /// How many characters (code points) before the cursor to take back.
  final int backspaces;

  /// The text to send after the backspaces.
  final String text;

  bool get isEmpty => backspaces == 0 && text.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is TextInputEdit &&
      other.backspaces == backspaces &&
      other.text == text;

  @override
  int get hashCode => Object.hash(backspaces, text);

  @override
  String toString() => 'TextInputEdit($backspaces, ${_quote(text)})';

  static String _quote(String text) => "'${text.replaceAll('\n', r'\n')}'";
}

/// Follows the editing value of the platform's input method and works out
/// what the terminal has to receive for every change of it.
///
/// A terminal cannot edit what it has already received. So the platform's
/// text is kept as it is (instead of being cleared after every keystroke),
/// and each change is turned into Backspace presses for the received
/// characters that changed, followed by the new text. That covers what
/// keyboards do besides typing: a suggestion that replaces the word being
/// typed (`Da` -> `Dad `), a composition that commits (`ni` -> `你`), a
/// deletion of several characters at once.
///
/// Composing text stays out of the terminal until it is committed; only the
/// part of a composition that the terminal already has (a keyboard that
/// composes a committed word again) is left there.
///
/// The platform's value starts as [initialValue]. A non-empty one (two
/// spaces) leaves the keyboard something to delete when nothing has been
/// typed yet, so that Backspace still reaches the terminal; its characters
/// count as already received, like the rest of the line.
class TextInputTracker {
  TextInputTracker(this.initialValue)
      : _current = _Lineage(initialValue, initialValue.text);

  /// The value the platform's text goes back to on [reset].
  final TextEditingValue initialValue;

  /// The text is put back to [initialValue] once it grows longer than this.
  static const maxLength = 256;

  _Lineage _current;

  /// A value the platform still edits after this side has reset it: the
  /// platform takes a reset some time after it has been sent. All of its
  /// text is taken as received, since the text edit resets only when no
  /// composition is in progress; edits on it follow one another here.
  _Lineage? _stale;

  bool _newlineEchoExpected = false;

  /// The platform's editing value, as far as it has been reported.
  TextEditingValue get value => _current.value;

  /// Whether the input method is composing text.
  bool get isComposing => _composingRange(_current.value) != null;

  /// The part of the composing text that the terminal does not have yet, or
  /// null if there is none.
  String? get composingText {
    final value = _current.value;
    final range = _composingRange(value);
    if (range == null) return null;
    final text = value.text;
    final sent = _current.sent;
    final pending = switch (range.end == text.length &&
        sent.length >= range.start &&
        text.startsWith(sent)) {
      true => text.substring(sent.length),
      false => text.substring(range.start, range.end),
    };
    return pending.isEmpty ? null : pending;
  }

  /// Whether the platform's text should be put back to [initialValue] now:
  /// a word or line was finished, the keyboard deleted into the initial
  /// text, or the text grew too long. Never while composing.
  bool get wantsReset {
    if (isComposing) return false;
    final text = _current.value.text;
    if (text == initialValue.text) return false;
    if (text.length < initialValue.text.length) return true;
    if (text.length > maxLength) return true;
    return text.isNotEmpty && _isWhitespace(text.codeUnitAt(text.length - 1));
  }

  /// Applies [deltas] reported by the platform and returns what the terminal
  /// has to receive, in order.
  List<TextInputEdit> applyDeltas(List<TextEditingDelta> deltas) {
    final edits = <TextInputEdit>[];
    for (final delta in deltas) {
      final lineage = _lineageFor(delta.oldText);
      final next = delta.apply(lineage.value);
      final target = _terminalText(next, lineage.sent);
      if (!_isNewlineEcho(delta)) {
        _addEdit(edits, _edit(lineage.sent, target));
      }
      lineage
        ..value = next
        ..sent = target;
    }
    return edits;
  }

  /// Applies a whole new [value], for platforms that do not report deltas.
  List<TextInputEdit> applyValue(TextEditingValue value) {
    _stale = null;
    if (value.text != _current.value.text) _newlineEchoExpected = false;
    final target = _terminalText(value, _current.sent);
    final edit = _edit(_current.sent, target);
    _current
      ..value = value
      ..sent = target;
    return edit.isEmpty ? const [] : [edit];
  }

  /// Tells that a newline action has just sent Enter to the terminal.
  ///
  /// iOS reports the newline action and then inserts `\n` into the text as
  /// well; that insertion must not reach the terminal a second time.
  void expectNewlineEcho() {
    _newlineEchoExpected = true;
  }

  /// Puts the platform's text back to [value] (by default [initialValue]),
  /// whose text counts as received by the terminal. The caller sends the
  /// value to the platform.
  void reset([TextEditingValue? value]) {
    final next = value ?? initialValue;
    _current = _Lineage(next, next.text);
  }

  _Lineage _lineageFor(String oldText) {
    if (oldText == _current.value.text) {
      // The platform has caught up with the last reset.
      _stale = null;
      return _current;
    }
    final stale = _stale;
    if (stale != null && oldText == stale.value.text) return stale;
    // Made on a value this side has reset.
    return _stale = _Lineage(
      TextEditingValue(
        text: oldText,
        selection: TextSelection.collapsed(offset: oldText.length),
      ),
      oldText,
    );
  }

  bool _isNewlineEcho(TextEditingDelta delta) {
    if (!_newlineEchoExpected || delta is TextEditingDeltaNonTextUpdate) {
      return false;
    }
    _newlineEchoExpected = false;
    return delta is TextEditingDeltaInsertion && delta.textInserted == '\n';
  }
}

class _Lineage {
  _Lineage(this.value, this.sent);

  /// The platform's editing value.
  TextEditingValue value;

  /// The text the terminal has, counted from the start of [value]'s text: the
  /// text outside the composing region, and the start of the composing text
  /// that the terminal had already received.
  String sent;
}

/// The text the terminal should have for [value], given that it has [sent].
String _terminalText(TextEditingValue value, String sent) {
  final text = value.text;
  final range = _composingRange(value);
  if (range == null) return text;
  // Composing inside the text, not at its end: leave the terminal alone until
  // the composition ends.
  if (range.end < text.length) return sent;
  final committed = text.substring(0, range.start);
  if (!sent.startsWith(committed)) return committed;
  final kept = _commonPrefixLength(
    text.substring(range.start),
    sent.substring(range.start),
  );
  return text.substring(0, range.start + kept);
}

/// The Backspace presses and text that turn [from] into [to] at the cursor.
TextInputEdit _edit(String from, String to) {
  final common = _commonPrefixLength(from, to);
  return TextInputEdit(
    from.substring(common).runes.length,
    to.substring(common),
  );
}

void _addEdit(List<TextInputEdit> edits, TextInputEdit edit) {
  if (edit.isEmpty) return;
  // Text right after text goes out in one piece, as one platform update used
  // to (a suggestion is reported as a replacement and then a space).
  if (edits.isNotEmpty && edit.backspaces == 0) {
    final last = edits.removeLast();
    edits.add(TextInputEdit(last.backspaces, last.text + edit.text));
    return;
  }
  edits.add(edit);
}

/// The composing range of [value] within its text, or null if it is not
/// composing.
TextRange? _composingRange(TextEditingValue value) {
  final composing = value.composing;
  if (!composing.isValid || composing.isCollapsed) return null;
  final length = value.text.length;
  final start = math.min(composing.start, composing.end).clamp(0, length);
  final end = math.max(composing.start, composing.end).clamp(0, length);
  if (start >= end) return null;
  return TextRange(start: start, end: end);
}

/// The length of the common start of [a] and [b] in UTF-16 code units,
/// never ending inside a surrogate pair.
int _commonPrefixLength(String a, String b) {
  final limit = math.min(a.length, b.length);
  var length = 0;
  while (length < limit && a.codeUnitAt(length) == b.codeUnitAt(length)) {
    length++;
  }
  if (length > 0 && _isHighSurrogate(a.codeUnitAt(length - 1))) length--;
  return length;
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isWhitespace(int codeUnit) => switch (codeUnit) {
      0x09 || 0x0A || 0x0D || 0x20 || 0x3000 => true,
      _ => false,
    };
