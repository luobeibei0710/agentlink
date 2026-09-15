// UI-only emulator fixture. Never used by lib/main.dart or release builds.
import 'package:companion/app_model.dart';
import 'package:companion/domain.dart';
import 'package:companion/hapi_api.dart';
import 'package:companion/main.dart' as app;
import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = PreviewApi();
  final model = AppModel(initialApi: api, persistState: false);
  await model.refresh();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Banner(
        message: '演示数据',
        location: BannerLocation.topEnd,
        child: app.AgentLink(model: model, receiveLinks: false),
      ),
    ),
  );
}

class PreviewApi extends HapiApi {
  PreviewApi()
    : super(Uri.parse('https://preview.invalid'), 'not-a-credential');
  bool approved = false;
  final replies = <String, List<ChatMessage>>{};
  @override
  Future<List<SessionSummary>> sessions() async => [
    const SessionSummary(
      id: 'chat',
      title: '完善 Android 连接流程',
      cwd: '/Projects/AgentLink',
      flavor: 'codex',
      active: true,
      thinking: true,
      updatedAt: 1,
    ),
    SessionSummary(
      id: 'approve',
      title: '补充连接状态测试',
      cwd: '/Projects/AgentLink',
      flavor: 'codebuddy',
      active: true,
      pending: approved ? 0 : 1,
      updatedAt: 2,
    ),
    const SessionSummary(
      id: 'history',
      title: '整理项目文档',
      cwd: '/Projects/AgentLink',
      flavor: 'codex',
      active: false,
      updatedAt: 0,
    ),
  ];
  @override
  Future<List<Machine>> machines() async => [
    const Machine(id: 'host', name: 'MacBook Pro · 演示', active: true),
  ];
  @override
  Future<List<AgentAvailability>> agentAvailability(String id) async => [
    const AgentAvailability(agent: 'codex', available: true),
    const AgentAvailability(agent: 'codebuddy', available: true),
  ];
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
  }) async => MessagePage(
    messages: [
      const ChatMessage(
        id: 'u',
        localId: '',
        role: 'user',
        view: MessageView.user,
        text: '完善连接状态页面，断网时保留内容并提供明确的恢复入口。',
        createdAt: 1,
        seq: 1,
      ),
      const ChatMessage(
        id: 'a',
        localId: '',
        role: 'assistant',
        view: MessageView.agentText,
        text: '我会先检查连接状态和重试逻辑，再补充对应的页面状态。',
        createdAt: 2,
        seq: 2,
      ),
      const ChatMessage(
        id: 't',
        localId: '',
        role: 'assistant',
        view: MessageView.toolCall,
        text: 'Read',
        toolName: 'Read',
        toolInput: {'path': 'lib/app_model.dart'},
        createdAt: 3,
        seq: 3,
      ),
      ...?replies[id],
    ],
    hasMore: false,
  );
  @override
  Future<List<PendingRequest>> pending(String id) async =>
      id == 'approve' && !approved
      ? [
          const PendingRequest(
            id: 'req',
            sessionId: 'approve',
            tool: 'Bash',
            kind: 'permission',
            args: {
              'command': 'flutter test',
              'cwd': '/Projects/AgentLink/flutter',
            },
          ),
        ]
      : [];
  @override
  Future<void> decide(
    String id,
    String request,
    bool allow, {
    Map<String, dynamic>? answers,
  }) async {
    approved = true;
  }

  @override
  Future<void> send(String id, String text, String localId) async {
    replies
        .putIfAbsent(id, () => [])
        .add(
          ChatMessage(
            id: localId,
            localId: localId,
            role: 'user',
            view: MessageView.user,
            text: text,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  @override
  Future<void> abort(String id) async {}
  @override
  Future<void> rename(String id, String name) async {}
}
