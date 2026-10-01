import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:xterm2/src/ui/text_input_tracker.dart';

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    int? viewId,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
  }) : viewId = viewId ?? PlatformDispatcher.instance.implicitView?.viewId {
    if (this.viewId == null) {
      throw Exception('Cannot open input connection without a valid viewId.');
    }
  }

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  /// Keeps two spaces before the cursor in the platform's text, so that the
  /// keyboard has something to delete when nothing has been typed yet and
  /// Backspace still reaches the terminal.
  final bool deleteDetection;

  final int? viewId;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

/// Sends what the platform's input method types to the terminal.
///
/// The platform reports its changes as deltas, which [TextInputTracker] turns
/// into Backspace presses and text for the terminal ([CustomTextEdit.onDelete]
/// and [CustomTextEdit.onInsert]). The platform's text is kept while a word
/// is being typed, so that the keyboard can replace the word (a suggestion);
/// it goes back to the initial value once a word or line is finished, or when
/// the terminal received input from elsewhere ([resetEditingState]).
class CustomTextEditState extends State<CustomTextEdit>
    with TextInputClient, DeltaTextInputClient {
  TextInputConnection? _connection;

  late var _tracker = TextInputTracker(_initEditingState);

  /// A reset that waits for the composition in progress to end.
  var _resetPending = false;

  /// What [CustomTextEdit.onComposing] was last told.
  String? _composingText;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection => _connection != null && _connection!.attached;

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  /// Sets the platform's editing value. Its text counts as already received
  /// by the terminal.
  void setEditingState(TextEditingValue value) {
    _resetPending = false;
    _tracker.reset(value);
    if (hasInputConnection) {
      _connection!.setEditingState(value);
    }
  }

  /// Tells that the terminal received input that did not come from the input
  /// method (a hardware key, an on-screen key, a paste).
  ///
  /// What the input method has typed so far may no longer be what the
  /// terminal shows, so it must not be offered for replacement: the
  /// platform's text goes back to the initial value, after the composition in
  /// progress (if any) has ended.
  void resetEditingState() {
    _resetWhenPossible();
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }

    _connection?.setEditableSizeAndTransform(
      rect.size,
      Matrix4.translationValues(0, 0, 0),
    );

    _connection?.setCaretRect(caretRect);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (_tracker.value.composing.isCollapsed) {
      return widget.onKeyEvent(focusNode, event);
    }

    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus && widget.focusNode.consumeKeyboardToken()) {
      _openInputConnection();
    } else if (!widget.focusNode.hasFocus) {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }

    if (hasInputConnection) {
      _connection!.show();
    } else {
      final config = TextInputConfiguration(
        viewId: widget.viewId,
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        // Changes come as deltas: in a whole new value a replacement (a
        // suggestion, a committed composition) cannot be told from typing.
        enableDeltaModel: true,
        // The text is kept while a word is typed, so iOS would see `--` and
        // straight quotes and turn them into a dash and curly quotes.
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
      );

      _connection = TextInput.attach(this, config);

      _connection!.show();

      // setEditableRect(Rect.zero, Rect.zero);

      _tracker = TextInputTracker(_initEditingState);
      _resetPending = false;
      _connection!.setEditingState(_tracker.value);
      _updateComposingText();
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
  }

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  @override
  TextEditingValue? get currentTextEditingValue {
    return _tracker.value;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    _send(_tracker.applyDeltas(textEditingDeltas));
  }

  /// A whole new value, from a platform that does not report deltas.
  @override
  void updateEditingValue(TextEditingValue value) {
    _send(_tracker.applyValue(value));
  }

  void _send(List<TextInputEdit> edits) {
    for (final edit in edits) {
      for (var i = 0; i < edit.backspaces; i++) {
        widget.onDelete();
      }
      if (edit.text.isNotEmpty) {
        widget.onInsert(edit.text);
      }
    }
    _updateComposingText();
    if (_resetPending || _tracker.wantsReset) {
      _resetWhenPossible();
    }
  }

  void _resetWhenPossible() {
    if (_tracker.isComposing) {
      _resetPending = true;
      return;
    }
    _resetPending = false;
    if (_tracker.value == _tracker.initialValue) return;
    _tracker.reset();
    if (hasInputConnection) {
      _connection!.setEditingState(_tracker.value);
    }
  }

  void _updateComposingText() {
    final text = _tracker.composingText;
    if (text == _composingText) return;
    _composingText = text;
    widget.onComposing(text);
  }

  @override
  void performAction(TextInputAction action) {
    widget.onAction(action);
    if (action == TextInputAction.newline) {
      _tracker.expectNewlineEcho();
    }
    // The line is done.
    _resetWhenPossible();
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    _tracker = TextInputTracker(_initEditingState);
    _resetPending = false;
    if (mounted) _updateComposingText();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }
}
