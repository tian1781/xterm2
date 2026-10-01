import 'package:flutter/services.dart';

/// Plays the platform side of text input: holds the platform's editing value
/// and reports every change as an encoded delta, the way the iOS and Android
/// engines send `TextInputClient.updateEditingStateWithDeltas`.
class FakeInputMethod {
  FakeInputMethod([TextEditingValue? value])
      : value = value ?? TextEditingValue.empty;

  TextEditingValue value;

  /// Types [text] at the cursor, or in place of the composition in progress,
  /// which ends (iOS `insertText`, Android `commitText`).
  Map<String, dynamic> type(String text) {
    final range = _composingOrSelection;
    return _replace(range.start, range.end, text);
  }

  /// Deletes the character before the cursor (iOS `deleteBackward`, Android
  /// `deleteSurroundingText(1, 0)`).
  Map<String, dynamic> backspace() {
    final text = value.text;
    final caret = value.selection.baseOffset;
    var start = caret - 1;
    if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start--;
    return _replace(start, caret, '');
  }

  /// Replaces `[start, end)` with [text], as a suggestion does (iOS
  /// `replaceRange:withText:`).
  Map<String, dynamic> replace(int start, int end, String text) =>
      _replace(start, end, text);

  /// Composes [text] in place of the composition in progress, or at the
  /// cursor (iOS `setMarkedText`, Android `setComposingText`).
  Map<String, dynamic> compose(String text) {
    final range = _composingOrSelection;
    return _replace(
      range.start,
      range.end,
      text,
      composing: TextRange(start: range.start, end: range.start + text.length),
    );
  }

  /// Ends the composition and keeps its text (iOS `unmarkText`, Android
  /// `finishComposingText`).
  Map<String, dynamic> finishComposing() => _nonText(TextRange.empty);

  /// Marks `[start, end)` as composing again (Android `setComposingRegion`).
  Map<String, dynamic> composeRegion(int start, int end) =>
      _nonText(TextRange(start: start, end: end));

  TextRange get _composingOrSelection {
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) return composing;
    return TextRange(start: value.selection.start, end: value.selection.end);
  }

  Map<String, dynamic> _replace(
    int start,
    int end,
    String text, {
    TextRange composing = TextRange.empty,
  }) {
    final oldText = value.text;
    final caret = start + text.length;
    value = TextEditingValue(
      text: oldText.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: caret),
      composing: composing,
    );
    return _encode(oldText, text, start, end);
  }

  Map<String, dynamic> _nonText(TextRange composing) {
    value = value.copyWith(composing: composing);
    return _encode(value.text, '', -1, -1);
  }

  Map<String, dynamic> _encode(
    String oldText,
    String deltaText,
    int deltaStart,
    int deltaEnd,
  ) {
    return {
      'oldText': oldText,
      'deltaText': deltaText,
      'deltaStart': deltaStart,
      'deltaEnd': deltaEnd,
      'selectionBase': value.selection.baseOffset,
      'selectionExtent': value.selection.extentOffset,
      'selectionAffinity': 'TextAffinity.downstream',
      'selectionIsDirectional': false,
      'composingBase': value.composing.start,
      'composingExtent': value.composing.end,
    };
  }

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
}
