import 'dart:convert';
import 'dart:io';
import 'package:companion/domain.dart';
import 'package:companion/input_answers.dart';
import 'package:flutter_test/flutter_test.dart';

PendingRequest request(String tool, Map<String, dynamic> args) =>
    PendingRequest(
      id: 'r',
      sessionId: 's',
      tool: tool,
      kind: 'input',
      args: args,
    );
void main() {
  test('AskUserQuestion formats numeric flat answers', () {
    final form = InputAnswers(
      request('AskUserQuestion', {
        'questions': [
          {
            'id': 'stable-a',
            'question': 'DB?',
            'options': [
              {'label': 'SQLite'},
              {'label': 'Postgres'},
            ],
          },
          {
            'question': 'Cache?',
            'options': [
              {'label': 'Redis'},
            ],
            'multiSelect': true,
          },
        ],
      }),
    );
    form.select('0', 'SQLite', true);
    form.select('1', 'Redis', true);
    expect(form.valid, isTrue);
    expect(form.format(), {
      '0': ['SQLite'],
      '1': ['Redis'],
    });
    form.note('0', '保持离线可用');
    expect(form.format()['0'], ['SQLite', '保持离线可用']);
  });
  test(
    'request_user_input preserves selected options and user note nested',
    () {
      final form = InputAnswers(
        request('request_user_input', {
          'questions': [
            {
              'id': 'deploy',
              'question': 'Target',
              'options': [
                {'label': 'staging', 'description': 'safe'},
              ],
              'required': true,
            },
            {
              'id': 'notes',
              'question': 'Notes',
              'inputType': 'editor',
              'prefill': 'keep',
              'required': true,
            },
          ],
        }),
      );
      form.select('deploy', 'staging', true);
      expect(form.valid, isTrue);
      expect(form.format(), {
        'deploy': {
          'answers': ['staging'],
        },
        'notes': {
          'answers': ['user_note: keep'],
        },
      });
    },
  );
  test('unsupported and unfilled required requests fail closed', () {
    final unsupported = InputAnswers(request('shell', {}));
    expect(unsupported.supported, isFalse);
    expect(unsupported.valid, isFalse);
    expect(
      InputAnswers(
        request('CursorAskQuestion', {
          'questions': [
            {
              'id': 'q',
              'prompt': 'Choose',
              'options': [
                {'id': 'x', 'label': 'X'},
              ],
            },
          ],
        }),
      ).supported,
      isFalse,
    );
    final required = InputAnswers(
      request('request_user_input', {
        'questions': [
          {
            'id': 'x',
            'question': 'X',
            'options': [
              {'label': 'a'},
            ],
          },
        ],
      }),
    );
    expect(required.valid, isFalse);
    expect(() => required.format(), throwsStateError);
    expect(
      InputAnswers(request('request_user_input', {'questions': []})).supported,
      isFalse,
    );
    expect(
      InputAnswers(
        request('request_user_input', {
          'questions': [
            {'id': 'x'},
            {'id': 'x'},
          ],
        }),
      ).supported,
      isFalse,
    );
  });
  test('AskUserQuestion free-text uses its stable numeric key', () {
    final form = InputAnswers(
      request('ask_user_question', {
        'questions': [
          {'question': 'Other?'},
        ],
      }),
    );
    form.note('0', '  custom value  ');
    expect(form.valid, isTrue);
    expect(form.format(), {
      '0': ['custom value'],
    });
  });
  test(
    'golden answer shapes use flat AskUserQuestion and nested request_user_input',
    () {
      final flat = jsonDecode(
        File(
          '../shared/fixtures/chat/permission-ask-user-question-answered.json',
        ).readAsStringSync(),
      ).toString();
      final nested = jsonDecode(
        File(
          '../shared/fixtures/chat/permission-request-user-input-answered.json',
        ).readAsStringSync(),
      ).toString();
      expect(flat, contains('{0: [SQLite]}'));
      expect(nested, contains('{deploy_target: {answers: [staging]}}'));
    },
  );
}
