import 'dart:async';

import 'package:companion/app_model.dart';
import 'package:companion/domain.dart';
import 'package:companion/hapi_api.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

typedef PageHandler =
    Future<MessagePage> Function(
      String id, {
      int? beforeSeq,
      int? beforeAt,
      int? afterSeq,
      int? afterAt,
      int? untilSeq,
      int? untilAt,
      int? epoch,
    });

class MemoryStorage extends FlutterSecureStorage {
  final values = <String, String>{};
  bool failWrites = false;
  int writesInFlight = 0, maxWritesInFlight = 0;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writesInFlight++;
    if (writesInFlight > maxWritesInFlight) maxWritesInFlight = writesInFlight;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    writesInFlight--;
    if (failWrites) throw StateError('storage failed');
    value == null ? values.remove(key) : values[key] = value;
  }
}

class FakeApi extends HapiApi {
  FakeApi({Uri? hub, String token = 'test-token'})
    : super(hub ?? Uri.parse('https://hub.example'), token);
  List<SessionSummary> sessionRows = const [
    SessionSummary(
      id: 'a',
      title: 'Codex',
      cwd: '/one',
      flavor: 'codex',
      active: true,
      updatedAt: 1,
    ),
    SessionSummary(
      id: 'b',
      title: 'CodeBuddy',
      cwd: '/two',
      flavor: 'codebuddy',
      active: true,
      updatedAt: 2,
    ),
  ];
  PageHandler? pageHandler;
  Future<List<PendingRequest>> Function(String)? pendingHandler;
  Future<List<SessionSummary>> Function()? sessionsHandler;
  Future<List<Machine>> Function()? machinesHandler;
  Future<String> Function(String)? resumeHandler;
  int resumeCalls = 0;
  Future<void> Function(String, String, String)? sendHandler;
  Future<CancellationResult> Function(String, String)? cancelHandler;
  Future<void> Function(String, String, bool, Map<String, dynamic>?)?
  decisionHandler;
  final sent = <(String, String, String)>[];
  final decisions = <(String, String, bool, Map<String, dynamic>?)>[];
  bool closed = false;

  @override
  Future<Map<String, dynamic>> health() async => {
    'status': 'ok',
    'protocolVersion': 1,
  };
  @override
  Future<void> authenticate() async {}
  @override
  void close() => closed = true;
  @override
  Future<List<SessionSummary>> sessions() =>
      sessionsHandler?.call() ?? Future.value(sessionRows);
  @override
  Future<List<Machine>> machines() =>
      machinesHandler?.call() ?? Future.value(const []);
  @override
  Future<MessagePage> messagePageWithCursors(
    String id, {
    int? beforeSeq,
    int? beforeAt,
    int? afterSeq,
    int? afterAt,
    int? untilSeq,
    int? untilAt,
    int? epoch,
  }) =>
      pageHandler?.call(
        id,
        beforeSeq: beforeSeq,
        beforeAt: beforeAt,
        afterSeq: afterSeq,
        afterAt: afterAt,
        untilSeq: untilSeq,
        untilAt: untilAt,
        epoch: epoch,
      ) ??
      Future.value(
        MessagePage(
          messages: [msg('$id-message', id, 10, 100)],
          hasMore: false,
          snapshotHeadSeq: 10,
          snapshotHeadAt: 100,
          epoch: 1,
        ),
      );
  @override
  Future<List<PendingRequest>> pending(String id) =>
      pendingHandler?.call(id) ?? Future.value(const []);
  @override
  Future<void> send(String id, String text, String localId) async {
    sent.add((id, text, localId));
    await sendHandler?.call(id, text, localId);
  }

  @override
  Future<void> decide(
    String sessionId,
    String requestId,
    bool allow, {
    Map<String, dynamic>? answers,
  }) async {
    decisions.add((sessionId, requestId, allow, answers));
    await decisionHandler?.call(sessionId, requestId, allow, answers);
  }

  final permissionModeCalls = <(String, String)>[];
  @override
  Future<void> setPermissionMode(String id, String mode) async {
    permissionModeCalls.add((id, mode));
  }

  final modelCalls = <(String, String)>[];
  @override
  Future<void> setModel(String id, String model) async {
    modelCalls.add((id, model));
  }

  /// 电脑端返回的用量总览。
  UsageSummary? usageRows;
  /// 记录拉取用量时用的范围与时区，用于验证参数传递。
  (String, String)? usageArgs;
  @override
  Future<UsageSummary> usageSummary(String range, String timeZone) async {
    usageArgs = (range, timeZone);
    return usageRows ?? UsageSummary.fromJson(const {});
  }

  /// 电脑端返回的模型列表；null 表示该会话取不到列表。
  List<ModelOption>? modelRows;
  /// 记录拉取列表时用的 flavor，用于验证端点选择。
  String? modelsFlavor;
  @override
  Future<List<ModelOption>?> models(String id, String flavor) async {
    modelsFlavor = flavor;
    return modelRows;
  }

  @override
  Future<String> resume(String id) {
    resumeCalls++;
    return resumeHandler?.call(id) ?? Future.value('$id-resumed');
  }

  @override
  Future<CancellationResult> cancelMessage(
    String sessionId,
    String messageId,
  ) =>
      cancelHandler?.call(sessionId, messageId) ??
      Future.value(CancellationResult(status: 'cancelled', localId: messageId));
}

ChatMessage msg(
  String id,
  String text,
  int seq,
  int at, {
  String localId = '',
  String? streamId,
  bool pending = false,
}) => ChatMessage(
  id: id,
  localId: localId,
  role: id.startsWith('user') ? 'user' : 'agent',
  view: id.startsWith('user') ? MessageView.user : MessageView.agentText,
  text: text,
  createdAt: at,
  invokedAt: at,
  hasInvokedAt: true,
  seq: seq,
  streamId: streamId,
  pending: pending,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'refresh gets both catalogs and late open cannot replace selection',
    () async {
      final api = FakeApi();
      final delayedA = Completer<MessagePage>();
      api.pageHandler =
          (
            id, {
            beforeSeq,
            beforeAt,
            afterSeq,
            afterAt,
            untilSeq,
            untilAt,
            epoch,
          }) => id == 'a'
          ? delayedA.future
          : Future.value(
              MessagePage(
                messages: [msg('b-1', 'b message', 1, 1)],
                hasMore: false,
                snapshotHeadSeq: 1,
                snapshotHeadAt: 1,
                epoch: 1,
              ),
            );
      final model = AppModel(initialApi: api, persistState: false);
      await model.refresh();
      expect(
        model.sessions.map((row) => row.flavor),
        containsAll(['codex', 'codebuddy']),
      );
      final openingA = model.openSession('a');
      await model.openSession('b');
      delayedA.complete(
        MessagePage(messages: [msg('a-1', 'stale', 1, 1)], hasMore: false),
      );
      await openingA;
      expect(model.selectedSession, 'b');
      expect(model.messages.single.text, 'b message');
      model.dispose();
    },
  );

  test('approval unlocks after a failed preflight or POST', () async {
    final api = FakeApi();
    const request = PendingRequest(
      id: 'request-b',
      sessionId: 'b',
      tool: 'shell',
      kind: 'permission',
    );
    api.pendingHandler = (_) async => [request];
    api.decisionHandler = (_, _, _, _) async => throw HubException('rejected');
    final model = AppModel(initialApi: api, persistState: false);
    await model.openSession('b');
    await model.decide(request, true);
    expect(model.submittedRequests, isEmpty);
    await model.decide(request, true);
    expect(api.decisions, hasLength(2));
    model.dispose();
  });

  test('pair link is strict and rejects ambiguous credentials', () async {
    late FakeApi created;
    final model = AppModel(
      persistState: false,
      apiFactory: (hub, token) => created = FakeApi(hub: hub, token: token),
    );
    await model.pairLink(
      'HAPICOMPANION://BIND?hub=https%3A%2F%2FHub.Example&code=first',
    );
    expect(created.baseUrl.toString(), 'https://hub.example');
    expect(created.accessToken, 'first');
    await expectLater(
      model.pairLink(
        'hapicompanion://bind?hub=https%3A%2F%2Fh.example&code=first&code=second',
      ),
      throwsA(isA<HubException>()),
    );
    await expectLater(
      model.pairLink(
        'hapicompanion://bind?hub=https%3A%2F%2Fh.example&code=%zz',
      ),
      throwsA(isA<HubException>()),
    );
    await expectLater(
      model.pairLink('hapicompanion://bind?hub=https%3A%2F%2Fh.example'),
      throwsA(isA<HubException>()),
    );
    model.dispose();
  });

  test(
    'catch-up preserves older history, reconciles echo, and coalesces streams',
    () async {
      final api = FakeApi();
      var deltaPage = 0;
      api.pageHandler =
          (
            id, {
            beforeSeq,
            beforeAt,
            afterSeq,
            afterAt,
            untilSeq,
            untilAt,
            epoch,
          }) async {
            if (beforeSeq != null) {
              return MessagePage(
                messages: [msg('old', 'old history', 1, 10)],
                hasMore: false,
                beforeSeq: 1,
                beforeAt: 10,
              );
            }
            if (afterSeq == null) {
              return MessagePage(
                messages: [msg('latest', 'latest', 10, 100)],
                hasMore: true,
                beforeSeq: 10,
                beforeAt: 100,
                snapshotHeadSeq: 10,
                snapshotHeadAt: 100,
                epoch: 7,
              );
            }
            deltaPage++;
            if (deltaPage == 1) {
              return MessagePage(
                messages: [
                  msg('reason-1', 'partial', 11, 110, streamId: 'thinking'),
                ],
                hasMore: true,
                afterSeq: 11,
                afterAt: 110,
                snapshotHeadSeq: 12,
                snapshotHeadAt: 120,
                epoch: 7,
                direction: 'after',
              );
            }
            return MessagePage(
              messages: [
                msg('reason-2', 'complete', 12, 120, streamId: 'thinking'),
                msg(
                  'user-server',
                  'hello',
                  13,
                  130,
                  localId: api.sent.single.$3,
                ),
              ],
              hasMore: false,
              afterSeq: 13,
              afterAt: 130,
              snapshotHeadSeq: 13,
              snapshotHeadAt: 130,
              epoch: 7,
              direction: 'after',
            );
          };
      final model = AppModel(initialApi: api, persistState: false);
      await model.openSession('b');
      await model.loadEarlier();
      await model.send('hello');
      expect(model.messages.map((row) => row.text), [
        'old history',
        'latest',
        'complete',
        'hello',
      ]);
      expect(
        model.messages.where((row) => row.localId == api.sent.single.$3),
        hasLength(1),
      );
      expect(model.messages.last.pending, isFalse);
      model.dispose();
    },
  );

  test(
    'durable outbox is stored before send and only retries its original id',
    () async {
      final storage = MemoryStorage();
      final apis = <FakeApi>[];
      FakeApi factory(Uri hub, String token) {
        final api = FakeApi(hub: hub, token: token);
        api.pageHandler =
            (
              id, {
              beforeSeq,
              beforeAt,
              afterSeq,
              afterAt,
              untilSeq,
              untilAt,
              epoch,
            }) async => const MessagePage(messages: [], hasMore: false);
        apis.add(api);
        return api;
      }

      final first = AppModel(storage: storage, apiFactory: factory);
      await first.pair('hub.example', 'secret');
      await first.openSession('b');
      first.setDraft('b', 'must not escape');
      storage.failWrites = true;
      await first.send('must not escape');
      expect(apis.single.sent, isEmpty);
      expect(first.error, contains('消息未发送'));
      expect(first.draftFor('b'), 'must not escape');
      storage.failWrites = false;
      await first.send('retry me');
      final localId = apis.single.sent.single.$3;
      expect(first.messages.single.localId, localId);
      first.dispose();

      final restored = AppModel(storage: storage, apiFactory: factory);
      await restored.restore();
      expect(restored.selectedSession, isNull);
      expect(restored.unresolvedMessages.single.sessionId, 'b');
      expect(restored.unresolvedMessages.single.message.localId, localId);
      expect(restored.unresolvedMessages.single.message.text, 'retry me');
      await restored.openSession('b');
      expect(restored.failedSends, contains(localId));
      await restored.send('wrong', retryLocalId: localId);
      expect(apis.last.sent, isEmpty);
      await restored.send('retry me', retryLocalId: localId);
      expect(apis.last.sent.single.$3, localId);
      expect(storage.maxWritesInFlight, 1);
      restored.closeSession();
      expect(restored.failedSends, isEmpty);
      expect(restored.unresolvedMessages.single.message.localId, localId);
      await restored.pair('another-hub.example', 'other-secret');
      expect(restored.unresolvedMessages, isEmpty);
      restored.dispose();
    },
  );

  test('queued cancellation follows the authoritative server result', () async {
    final api = FakeApi();
    api.pageHandler =
        (
          id, {
          beforeSeq,
          beforeAt,
          afterSeq,
          afterAt,
          untilSeq,
          untilAt,
          epoch,
        }) async => const MessagePage(messages: [], hasMore: false);
    final model = AppModel(initialApi: api, persistState: false);
    await model.openSession('b');
    await model.send('already invoked');
    final first = model.messages.single;
    expect(first.queued, isTrue);
    api.cancelHandler = (_, localId) async => CancellationResult(
      status: 'invoked',
      localId: localId,
      message: msg('server-user', 'already invoked', 4, 40, localId: localId),
    );
    await model.cancelMessage(first);
    expect(model.messages.single.pending, isFalse);
    expect(model.error, contains('已被代理接收'));

    await model.send('still queued');
    final queued = model.messages.last;
    api.cancelHandler = (_, localId) async =>
        CancellationResult(status: 'cancelled', localId: localId);
    await model.cancelMessage(queued);
    expect(model.messages.any((row) => row.localId == queued.localId), isFalse);
    model.dispose();
  });

  test(
    'approval validates owner and stays locked until authoritative clear',
    () async {
      final api = FakeApi();
      const request = PendingRequest(
        id: 'request-b',
        sessionId: 'b',
        tool: 'request_user_input',
        kind: 'input',
      );
      var pending = <PendingRequest>[request];
      api.pendingHandler = (_) async => pending;
      final model = AppModel(initialApi: api, persistState: false);
      await model.openSession('b');
      await model.decide(request, true, answers: {'choice': 'safe'});
      expect(api.decisions.single.$1, 'b');
      expect(api.decisions.single.$2, 'request-b');
      expect(api.decisions.single.$3, isTrue);
      expect(api.decisions.single.$4, {'choice': 'safe'});
      expect(model.submittedRequests, contains('request-b'));
      await model.decide(request, true);
      expect(api.decisions, hasLength(1));
      pending = [];
      await model.refreshOpen();
      expect(model.submittedRequests, isEmpty);
      await model.decide(
        const PendingRequest(
          id: 'foreign',
          sessionId: 'a',
          tool: 'shell',
          kind: 'permission',
        ),
        true,
      );
      expect(model.error, contains('不属于当前会话'));
      model.dispose();
    },
  );

  test(
    'logout invalidates in-flight pair and provider change clears incompatible selection',
    () async {
      final health = Completer<Map<String, dynamic>>();
      final api = _DelayedHealthApi(health.future);
      final model = AppModel(
        apiFactory: (_, _) => api,
        storage: MemoryStorage(),
      );
      final pairing = model.pair('hub.example', 'secret');
      await model.logout();
      health.complete({'status': 'ok', 'protocolVersion': 1});
      await pairing;
      expect(model.paired, isFalse);
      expect(model.loading, isFalse);
      expect(model.error, isNull);
      expect(api.closed, isTrue);
      model.dispose();

      final selected = AppModel(initialApi: FakeApi(), persistState: false);
      await selected.refresh();
      await selected.openSession('b');
      selected.setAgent('codex');
      expect(selected.selectedSession, isNull);
      selected.dispose();
    },
  );

  test('resume race does not migrate draft or rebind outbox', () async {
    final api = FakeApi();
    final resume = Completer<String>();
    api.resumeHandler = (_) => resume.future;
    final model = AppModel(initialApi: api, persistState: false);
    await model.openSession('b');
    model.setDraft('b', 'draft');
    await model.send('bound to b');
    final localId = api.sent.single.$3;
    final resuming = model.resumeSelected();
    final duplicate = model.resumeSelected();
    expect(model.resuming, contains('b'));
    await model.openSession('a');
    resume.complete('b-resumed');
    await resuming;
    await duplicate;
    expect(api.resumeCalls, 1);
    expect(model.resuming, isEmpty);
    expect(model.selectedSession, 'a');
    expect(model.draftFor('b'), 'draft');
    await model.openSession('b-resumed');
    expect(model.messages.where((row) => row.localId == localId), isEmpty);
    await model.openSession('b');
    expect(model.messages.where((row) => row.localId == localId), hasLength(1));
    model.dispose();
  });

  test('successful resume migrates only the draft', () async {
    final api = FakeApi();
    final model = AppModel(initialApi: api, persistState: false);
    await model.openSession('b');
    model.setDraft('b', 'continue here');
    await model.resumeSelected();
    expect(model.selectedSession, 'b-resumed');
    expect(model.draftFor('b'), isEmpty);
    expect(model.draftFor('b-resumed'), 'continue here');
    model.dispose();
  });

  test('permission mode change targets the open session and is remembered', () async {
    final api = FakeApi();
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');
    await model.openSession('a');

    // 未切换过时没有本地记录，表示沿用电脑端默认值。
    expect(model.permissionModeFor('a'), isNull);

    await model.setPermissionMode('read-only');
    expect(api.permissionModeCalls, [('a', 'read-only')]);
    expect(model.permissionModeFor('a'), 'read-only');

    // 切换会话不应把上一次的模式带到别的会话上。
    await model.openSession('b');
    expect(model.permissionModeFor('b'), isNull);
    model.dispose();
  });

  test('permission mode change without an open session is a no-op', () async {
    final api = FakeApi();
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');

    await model.setPermissionMode('yolo');

    expect(api.permissionModeCalls, isEmpty);
    model.dispose();
  });

  test('model change targets the open session and is remembered', () async {
    final api = FakeApi();
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');
    await model.openSession('a');

    expect(model.modelFor('a'), isNull);

    await model.setModel('deepseek-v4-pro');
    expect(api.modelCalls, [('a', 'deepseek-v4-pro')]);
    expect(model.modelFor('a'), 'deepseek-v4-pro');

    // 切换会话不应把上一个会话的模型带过去。
    await model.openSession('b');
    expect(model.modelFor('b'), isNull);
    model.dispose();
  });

  test('the model reported by the hub wins over the local record', () async {
    final api = FakeApi()
      ..sessionRows = const [
        SessionSummary(
          id: 'a',
          title: 'Codex',
          cwd: '/one',
          flavor: 'codex',
          active: true,
          updatedAt: 1,
          model: 'gpt-5-codex',
        ),
      ];
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');

    // 电脑端上报的值优先：它才反映真实模型，包括在电脑上改过的。
    expect(model.modelFor('a'), 'gpt-5-codex');
    model.dispose();
  });

  test('available models are fetched with the session flavor', () async {
    final api = FakeApi()
      ..sessionRows = const [
        SessionSummary(
          id: 'a',
          title: 'CodeBuddy',
          cwd: '/one',
          flavor: 'codebuddy',
          active: true,
          updatedAt: 1,
        ),
      ]
      ..modelRows = const [
        ModelOption('hy4-preview', 'Hy4 preview', note: 'x0.29 credits'),
        ModelOption('hy3', 'Hy3'),
      ];
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');

    final options = await model.availableModels('a');
    expect(api.modelsFlavor, 'codebuddy');
    expect(options, hasLength(2));
    expect(options!.first.label, 'Hy4 preview');
    expect(options.first.note, 'x0.29 credits');
    model.dispose();
  });

  test('a session without models reports null instead of an empty list', () async {
    final api = FakeApi()..modelRows = null;
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');

    // null 表示「这个会话不支持换模型」，界面据此不显示入口；
    // 空列表会被误解成「有入口但没有可选模型」。
    expect(await model.availableModels('a'), isNull);
    model.dispose();
  });

  test('loads the usage summary and passes the device time zone', () async {
    final api = FakeApi()
      ..usageRows = UsageSummary.fromJson({
        'totals': {
          'inputTokens': 1000,
          'outputTokens': 200,
          'totalTokens': 1200,
          'requests': 3,
          'sessions': 2,
        },
        'byAgent': [
          {'key': 'codebuddy', 'totalTokens': 1200, 'requests': 3},
        ],
      });
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');

    await model.loadUsage('30d');

    expect(api.usageArgs?.$1, '30d');
    // 时区必须能被电脑端的 Intl 接受，否则接口直接 400。
    expect(api.usageArgs?.$2, AppModel.deviceTimeZone());
    expect(model.usage?.managed.totals.totalTokens, 1200);
    expect(model.usage?.managed.sessions, 2);
    expect(model.usage?.managed.byAgent.single.key, 'codebuddy');
    model.dispose();
  });

  test('device time zone is a name the hub can parse', () {
    // Dart 拿不到 IANA 名，只能验证产出形态：UTC 或固定偏移的 Etc/GMT±N。
    // 半小时时区（如印度 +5:30）不在 Etc/GMT 的表达范围内，会退回 UTC。
    expect(
      AppModel.deviceTimeZone(),
      anyOf('UTC', matches(r'^Etc/GMT[+-]\d{1,2}$')),
    );
  });

  test('sending to an offline session resumes it before delivering', () async {
    // 导入的历史会话在电脑上没有进程（active=false）。
    final api = FakeApi()
      ..sessionRows = const [
        SessionSummary(
          id: 'a',
          title: 'Codex',
          cwd: '/one',
          flavor: 'codex',
          active: false,
          updatedAt: 1,
        ),
      ];
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');
    await model.openSession('a');

    await model.sendOrResume('继续这个任务');

    // 先把会话恢复起来，再把消息投递给恢复后的会话（电脑端会新建一个活跃会话）。
    expect(api.resumeCalls, 1);
    expect(api.sent.single.$1, 'a-resumed');
    expect(api.sent.single.$2, '继续这个任务');
    model.dispose();
  });

  test('sending to an online session skips the resume step', () async {
    final api = FakeApi();
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');
    await model.openSession('a');

    await model.sendOrResume('你好');

    expect(api.resumeCalls, 0);
    expect(api.sent.single.$1, 'a');
    expect(api.sent.single.$2, '你好');
    model.dispose();
  });

  test('a failed resume does not deliver the message', () async {
    final api = FakeApi()
      ..sessionRows = const [
        SessionSummary(
          id: 'a',
          title: 'Codex',
          cwd: '/one',
          flavor: 'codex',
          active: false,
          updatedAt: 1,
        ),
      ]
      ..resumeHandler = (_) => Future.error(HubException('恢复失败'));
    final model = AppModel(apiFactory: (_, _) => api, persistState: false);
    await model.pair('hub.example', 'token');
    await model.openSession('a');

    await model.sendOrResume('不该发出去');

    // 恢复不成功时不能继续投递：消息会落到已归档的会话上。
    expect(api.resumeCalls, 1);
    expect(api.sent, isEmpty);
    model.dispose();
  });

  test(
    'rejected replacement pairing preserves the existing live credential',
    () async {
      final storage = MemoryStorage();
      FakeApi factory(Uri hub, String token) => token == 'wrong'
          ? _RejectedAuthApi(hub: hub, token: token)
          : FakeApi(hub: hub, token: token);
      final model = AppModel(storage: storage, apiFactory: factory);
      await model.pair('hub.example', 'valid');
      final active = model.api;
      for (final target in ['hub.example', 'other.example']) {
        await expectLater(
          model.pair(target, 'wrong'),
          throwsA(isA<ApiException>()),
        );
        expect(model.api, same(active));
      }
      model.dispose();
      final restored = AppModel(storage: storage, apiFactory: factory);
      await restored.restore();
      expect(restored.paired, isTrue);
      expect(restored.api?.accessToken, 'valid');
      expect(restored.hub, 'https://hub.example');
      restored.dispose();
    },
  );

  test('same-id resume retains the existing draft', () async {
    final api = FakeApi()..resumeHandler = (id) async => id;
    final model = AppModel(initialApi: api, persistState: false);
    await model.openSession('b');
    model.setDraft('b', 'same native session');
    await model.resumeSelected();
    expect(model.selectedSession, 'b');
    expect(model.draftFor('b'), 'same native session');
    expect(api.resumeCalls, 1);
    model.dispose();
  });

  test(
    'revocation and rejected re-pair retain unsent work through restart',
    () async {
      final storage = MemoryStorage();
      final clients = <FakeApi>[];
      FakeApi factory(Uri hub, String token) {
        final client = token == 'wrong'
            ? _RejectedAuthApi(hub: hub, token: token)
            : FakeApi(hub: hub, token: token);
        clients.add(client);
        return client;
      }

      final model = AppModel(storage: storage, apiFactory: factory);
      await model.pair('hub.example', 'good');
      await model.openSession('a');
      await model.send('unconfirmed content');
      final localId = model.unresolvedMessages.single.message.localId;
      model.setDraft('b', 'keep draft');
      clients.last.sessionsHandler = () async =>
          throw ApiException('revoked', status: 401, terminalAuth: true);
      await model.refresh();
      expect(model.paired, isFalse);
      await expectLater(
        model.pair('hub.example', 'wrong'),
        throwsA(isA<ApiException>()),
      );
      model.dispose();

      final restored = AppModel(storage: storage, apiFactory: factory);
      await restored.restore();
      expect(restored.paired, isFalse);
      await restored.pair('hub.example', 'new-good');
      expect(restored.unresolvedMessages.single.message.localId, localId);
      expect(
        restored.unresolvedMessages.single.message.text,
        'unconfirmed content',
      );
      expect(restored.draftFor('b'), 'keep draft');
      await restored.logout();
      expect(restored.unresolvedMessages, isEmpty);
      restored.dispose();
    },
  );
}

class _RejectedAuthApi extends FakeApi {
  _RejectedAuthApi({required super.hub, required super.token});
  @override
  Future<void> authenticate() async =>
      throw ApiException('invalid credential', status: 401, terminalAuth: true);
}

class _DelayedHealthApi extends FakeApi {
  _DelayedHealthApi(this.result);
  final Future<Map<String, dynamic>> result;
  @override
  Future<Map<String, dynamic>> health() => result;
}
