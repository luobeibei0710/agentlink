import 'domain.dart';

class InputOption {
  const InputOption(this.label, this.description);
  final String label;
  final String? description;
}

class InputQuestion {
  const InputQuestion({
    required this.key,
    required this.question,
    required this.options,
    required this.multiple,
    required this.required,
    this.editor = false,
    this.prefill,
  });
  final String key, question;
  final List<InputOption> options;
  final bool multiple, required, editor;
  final String? prefill;
}

/// Mutable form state for the two HAPI interactive-tool wire protocols.
class InputAnswers {
  InputAnswers(PendingRequest request) : _tool = request.tool {
    final parsed = _parse(request);
    supported = parsed.$1;
    questions = parsed.$2;
    for (final q in questions) {
      _notes[q.key] = q.prefill ?? '';
      _selected[q.key] = <String>{};
    }
  }
  final String _tool;
  late final bool supported;
  late final List<InputQuestion> questions;
  final Map<String, Set<String>> _selected = {};
  final Map<String, String> _notes = {};
  void select(String key, String label, bool selected) {
    final q = _question(key);
    if (q == null || !q.options.any((o) => o.label == label)) return;
    final values = _selected[key]!;
    if (selected) {
      if (!q.multiple) values.clear();
      values.add(label);
    } else {
      values.remove(label);
    }
  }

  void note(String key, String value) {
    if (_question(key) != null) _notes[key] = value;
  }

  bool isSelected(String key, String label) =>
      _selected[key]?.contains(label) ?? false;
  bool get valid =>
      supported &&
      questions.every((q) {
        if (!q.required) return true;
        if (q.options.isNotEmpty) {
          return _selected[q.key]!.isNotEmpty ||
              (_tool != 'request_user_input' &&
                  _notes[q.key]!.trim().isNotEmpty);
        }
        return q.editor || _notes[q.key]!.trim().isNotEmpty;
      });
  Map<String, dynamic> format() {
    if (!valid) throw StateError('输入尚未完成或请求不受支持');
    if (_tool == 'request_user_input') {
      final answers = <String, dynamic>{};
      for (final q in questions) {
        final values = <String>[..._selected[q.key]!];
        final note = q.editor ? _notes[q.key]! : _notes[q.key]!.trim();
        if (q.editor || note.isNotEmpty) values.add('user_note: $note');
        answers[q.key] = {'answers': values};
      }
      return answers;
    }
    final answers = <String, dynamic>{};
    for (final q in questions) {
      final values = <String>[..._selected[q.key]!];
      final note = _notes[q.key]!.trim();
      if (note.isNotEmpty) values.add(note);
      answers[q.key] = values;
    }
    return answers;
  }

  InputQuestion? _question(String key) {
    for (final q in questions) {
      if (q.key == key) return q;
    }
    return null;
  }

  static (bool, List<InputQuestion>) _parse(PendingRequest request) {
    final args = request.args;
    final raw = args['questions'];
    if (raw is! List) return (false, const []);
    final nested = request.tool == 'request_user_input';
    final ask =
        request.tool == 'AskUserQuestion' ||
        request.tool == 'ask_user_question';
    if (!nested && !ask) return (false, const []);
    if (raw.isEmpty) return (false, const []);
    final output = <InputQuestion>[];
    final ids = <String>{};
    for (var index = 0; index < raw.length; index++) {
      final value = raw[index];
      if (value is! Map) return (false, const []);
      final row = value.cast<String, dynamic>();
      final id = (row['id'] is String ? (row['id'] as String).trim() : '');
      if (nested && id.isEmpty) return (false, const []);
      final key = nested ? id : '$index';
      if (!ids.add(key)) return (false, const []);
      final options = <InputOption>[];
      if (row['options'] is List)
        for (final item in row['options'] as List) {
          if (item is! Map) continue;
          final option = item.cast<String, dynamic>();
          final label = (option['label'] is String
              ? (option['label'] as String).trim()
              : '');
          if (label.isNotEmpty)
            options.add(
              InputOption(
                label,
                option['description'] is String
                    ? (option['description'] as String).trim()
                    : null,
              ),
            );
        }
      final editor = nested && row['inputType'] == 'editor';
      final question = (row['question'] is String
          ? (row['question'] as String).trim()
          : '');
      if (!nested && question.isEmpty && options.isEmpty)
        return (false, const []);
      output.add(
        InputQuestion(
          key: key,
          question: question,
          options: options,
          multiple: nested
              ? row['multiple'] == true
              : row['multiSelect'] == true,
          required: nested ? row['required'] != false : true,
          editor: editor,
          prefill: row['prefill'] is String ? row['prefill'] as String : null,
        ),
      );
    }
    return output.isEmpty ? (false, const []) : (true, output);
  }
}
