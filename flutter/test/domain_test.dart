import 'dart:convert';
import 'dart:io';
import 'package:companion/domain.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用给定的 `data` 载荷构造一条 agent 消息，便于逐条断言展示形态。
ChatMessage agentPayload(Map<String, dynamic> data) => ChatMessage.fromJson({
  'content': {
    'role': 'agent',
    'content': {'type': 'codex', 'data': data},
  },
});

void main() {
  test('usage and lifecycle records render as status lines, not chat prose', () {
    // 用量与目标状态属于事件：以居中状态行展示，而不是助手正文。
    final usage = agentPayload({
      'type': 'token_count',
      'secretInternalId': 'internal',
    });
    expect(usage.view, MessageView.status);
    expect(usage.text, 'Context updated');
    expect(usage.statusIcon, '◷');

    final cleared = agentPayload({'type': 'thread_goal_cleared'});
    expect(cleared.view, MessageView.status);
    expect(cleared.text, 'Goal cleared');

    // 无法识别的协议事件仍不参与展示。
    expect(agentPayload({'type': 'new_wire_event'}).view, MessageView.hidden);
    expect(
      ChatMessage.fromJson({
        'content': {
          'role': 'agent',
          'content': {
            'type': 'event',
            'data': {'type': 'ready'},
          },
        },
      }).view,
      MessageView.hidden,
    );
  });

  test('formats token usage exactly like the web status line', () {
    final usage = agentPayload({
      'type': 'token_count',
      'info': {
        'modelContextWindow': 200000,
        'total': {
          'inputTokens': 12000,
          'outputTokens': 1500,
          'cachedInputTokens': 3000,
        },
      },
    });
    expect(usage.view, MessageView.status);
    // 与 Web 端 presentation.ts 的 formatTokenCount 保持一致：>=10k 保留一位小数。
    expect(usage.text, 'Context 12.0k / 200.0k (6%) · out 2k · cached 3k');
  });

  test('splits tool calls and results into structured card fields', () {
    final call = agentPayload({
      'type': 'tool-call',
      'name': 'Read',
      'callId': 'call-7',
      'input': {'path': 'lib/main.dart'},
    });
    expect(call.view, MessageView.toolCall);
    expect(call.tool, isTrue);
    expect(call.toolName, 'Read');
    expect((call.toolInput as Map)['path'], 'lib/main.dart');

    final result = agentPayload({
      'type': 'tool-call-result',
      'callId': 'call-7',
      'output': {'stdout': 'ok'},
    });
    expect(result.view, MessageView.toolResult);
    expect(result.callId, 'call-7');
    expect(result.toolFailed, isFalse);
    expect((result.toolOutput as Map)['stdout'], 'ok');

    expect(
      agentPayload({
        'type': 'tool-call-result',
        'callId': 'call-8',
        'status': 'error',
        'output': 'boom',
      }).toolFailed,
      isTrue,
    );
  });
  test('unwraps actual role-wrapped codex message envelope', () {
    final message = ChatMessage.fromJson({
      'id': 'm1',
      'seq': 7,
      'content': {
        'role': 'agent',
        'content': {
          'type': 'codex',
          'data': {
            'type': 'message',
            'message': 'CodeBuddy reply',
            'id': 'stream-1',
          },
        },
      },
    });
    expect(message.role, 'agent');
    expect(message.text, 'CodeBuddy reply');
    expect(message.seq, 7);
    expect(message.streamId, 'stream-1');
    expect(message.tool, isFalse);
  });
  test('keeps reasoning as its own collapsible view', () {
    final reasoning = agentPayload({
      'type': 'reasoning',
      'message': 'considering',
    });
    expect(reasoning.view, MessageView.reasoning);
    expect(reasoning.text, 'considering');
    // 思考过程不是工具消息，不应被当成执行记录。
    expect(reasoning.tool, isFalse);
  });

  test('merges a tool result into the preceding call entry', () {
    final entries = buildChatEntries([
      agentPayload({
        'type': 'tool-call',
        'name': 'Read',
        'callId': 'call-7',
        'input': {'path': 'a.dart'},
      }),
      agentPayload({
        'type': 'tool-call-result',
        'callId': 'call-7',
        'output': 'done',
      }),
    ]);
    expect(entries, hasLength(1));
    expect(entries.single.message.toolName, 'Read');
    expect(entries.single.result?.toolOutput, 'done');
  });

  test('keeps an unpaired tool result as its own entry', () {
    final entries = buildChatEntries([
      agentPayload({
        'type': 'tool-call-result',
        'callId': 'orphan',
        'output': 'done',
      }),
    ]);
    expect(entries, hasLength(1));
    expect(entries.single.result, isNull);
    expect(entries.single.message.view, MessageView.toolResult);
  });

  test('formats relative time across the ranges the list shows', () {
    const now = 1789000000000;
    expect(formatRelativeTime(now - 30000, nowMs: now), '刚刚');
    expect(formatRelativeTime(now - 12 * 60000, nowMs: now), '12 分钟前');
    expect(formatRelativeTime(now - 23 * 3600000, nowMs: now), '23 小时前');
    expect(formatRelativeTime(now - 30 * 3600000, nowMs: now), '昨天');
    expect(formatRelativeTime(now - 3 * 86400000, nowMs: now), '3 天前');
    // 一周以上改用具体日期，避免出现「37 天前」这种不好换算的说法。
    expect(
      formatRelativeTime(now - 40 * 86400000, nowMs: now),
      matches(r'^\d+ 月 \d+ 日$'),
    );
    // 电脑时钟超前于手机时不应出现负数。
    expect(formatRelativeTime(now + 60000, nowMs: now), '刚刚');
  });

  test('derives session status with pending taking priority', () {
    SessionSummary build({
      bool active = true,
      bool thinking = false,
      int pending = 0,
    }) => SessionSummary(
      id: 's',
      title: 't',
      cwd: '/p',
      flavor: 'codex',
      active: active,
      updatedAt: 0,
      thinking: thinking,
      pending: pending,
    );

    // 有待确认的请求时优先展示，即使 Agent 还在执行。
    expect(
      SessionStatus.of(build(thinking: true, pending: 2)),
      SessionStatus.pending,
    );
    expect(SessionStatus.of(build(thinking: true)), SessionStatus.running);
    expect(SessionStatus.of(build()), SessionStatus.idle);
    expect(SessionStatus.of(build(active: false)), SessionStatus.ended);
    // 已结束的会话若仍报有待处理请求，按待处理处理，提示用户进去看一眼。
    expect(
      SessionStatus.of(build(active: false, pending: 1)),
      SessionStatus.pending,
    );
  });

  test('exposes the permission modes each agent actually supports', () {
    expect(permissionModesForFlavor('codex').map((o) => o.mode), [
      'default',
      'read-only',
      'safe-yolo',
      'yolo',
    ]);
    // CodeBuddy 与电脑端一致共 8 档，取自其 ACP 服务端下发的 configOptions，
    // 并且支持在会话运行中实时切换（顺序与电脑端一致）。
    expect(permissionModesForFlavor('codebuddy').map((o) => o.mode), [
      'default',
      'acceptEdits',
      'plan',
      'auto',
      'dontAsk',
      'bypassPermissions',
      'fullAccess',
      'delegate',
    ]);
    // 明确不支持运行时切换的类型不提供入口。
    expect(permissionModesForFlavor('pi'), isEmpty);
    expect(permissionModesForFlavor('dsh'), isEmpty);
    // 未知类型与电脑端一致，回退到 Claude 的模式集合。
    expect(permissionModesForFlavor('unknown').map((o) => o.mode), [
      'default',
      'acceptEdits',
      'auto',
      'plan',
      'bypassPermissions',
    ]);
    // 类型未知时不猜，保持无入口。
    expect(permissionModesForFlavor(''), isEmpty);
    // 跳过审批的模式必须被标记，界面上需要警示色。
    expect(
      permissionModesForFlavor('codex')
          .where((option) => option.warning)
          .map((option) => option.mode),
      ['yolo'],
    );
    // CodeBuddy 里只有真正跳过检查的两档需要警示，其余靠说明文字区分。
    expect(
      permissionModesForFlavor('codebuddy')
          .where((option) => option.warning)
          .map((option) => option.mode),
      ['bypassPermissions', 'fullAccess'],
    );
    // 每一档都要有说明，否则用户无法判断该选哪个。
    expect(
      permissionModesForFlavor('codebuddy').where(
        (option) => option.description == null,
      ),
      isEmpty,
    );
  });

  test('merges consecutive reasoning and infers its duration', () {
    ChatMessage reasoning(int at, String text) => ChatMessage(
      id: 'r-$at',
      localId: '',
      role: 'agent',
      view: MessageView.reasoning,
      text: text,
      createdAt: at,
    );
    ChatMessage reply(int at, String text) => ChatMessage(
      id: 'm-$at',
      localId: '',
      role: 'agent',
      view: MessageView.agentText,
      text: text,
      createdAt: at,
    );

    final entries = buildChatEntries([
      reasoning(1000, 'first'),
      reasoning(3000, 'second'),
      reply(13000, 'answer'),
    ]);

    expect(entries, hasLength(2));
    expect(entries.first.message.view, MessageView.reasoning);
    expect(entries.first.message.text, 'first\n\nsecond');
    // 耗时按整段思考的起点到后继消息计算。
    expect(entries.first.reasoningDurationMs, 12000);
    expect(entries.last.message.text, 'answer');
  });

  test('omits reasoning duration when the gap is not plausible', () {
    ChatMessage reasoning(int at) => ChatMessage(
      id: 'r-$at',
      localId: '',
      role: 'agent',
      view: MessageView.reasoning,
      text: 'thinking',
      createdAt: at,
    );
    ChatMessage reply(int at) => ChatMessage(
      id: 'm-$at',
      localId: '',
      role: 'agent',
      view: MessageView.agentText,
      text: 'answer',
      createdAt: at,
    );

    // 超过上限：多半是用户中途离开，不是真的思考了这么久。
    expect(
      buildChatEntries([reasoning(0), reply(60 * 60 * 1000)])
          .first
          .reasoningDurationMs,
      isNull,
    );
    // 低于下限：不足以说明耗时。
    expect(
      buildChatEntries([reasoning(0), reply(500)]).first.reasoningDurationMs,
      isNull,
    );
    // 没有后继消息时无法推算。
    expect(
      buildChatEntries([reasoning(0)]).first.reasoningDurationMs,
      isNull,
    );
  });

  test('drops hidden protocol events from rendered entries', () {
    final entries = buildChatEntries([
      agentPayload({'type': 'agent-run-trace'}),
      agentPayload({'type': 'message', 'message': 'visible'}),
    ]);
    expect(entries, hasLength(1));
    expect(entries.single.message.text, 'visible');
  });
  test('reads Claude output blocks and user text', () {
    final claude = ChatMessage.fromJson({
      'content': {
        'role': 'agent',
        'content': {
          'type': 'output',
          'data': {
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'text', 'text': 'one'},
                {'type': 'text', 'text': 'two'},
              ],
            },
          },
        },
      },
    });
    expect(claude.text, 'one\ntwo');
    expect(
      ChatMessage.fromJson({
        'content': {
          'role': 'user',
          'content': {'type': 'text', 'text': 'hello'},
        },
      }).text,
      'hello',
    );
  });
  test('pending input preserves session id and arguments', () {
    final p = PendingRequest.fromEntry('s1', 'r1', {
      'tool': 'request_user_input',
      'arguments': {'prompt': 'pick'},
    });
    expect(p.needsAnswer, isTrue);
    expect(p.sessionId, 's1');
    expect(p.args['prompt'], 'pick');
  });
  test('generated pagination fixture codex rows decode as visible text', () {
    final fixture =
        jsonDecode(
              File(
                '../shared/fixtures/pagination/fetch-older-before-cursor.json',
              ).readAsStringSync(),
            )
            as Map;
    final operations = fixture['ops'] as List;
    final row =
        (((operations.first as Map)['responses'] as List).first
                as Map)['messages']
            as List;
    final message = ChatMessage.fromJson(
      (row.first as Map).cast<String, dynamic>(),
    );
    expect(message.text, 'a-10');
    expect(message.invokedAt, 10000);
    expect(message.queued, isFalse);
  });
  test(
    'explicit null invokedAt is queued but omitted invokedAt is unknown',
    () {
      final queued = ChatMessage.fromJson({
        'content': {
          'role': 'user',
          'content': {'type': 'text', 'text': 'draft'},
        },
        'invokedAt': null,
      });
      final unknown = ChatMessage.fromJson({
        'content': {
          'role': 'user',
          'content': {'type': 'text', 'text': 'draft'},
        },
      });
      expect(queued.queued, isTrue);
      expect(unknown.queued, isFalse);
    },
  );
}
