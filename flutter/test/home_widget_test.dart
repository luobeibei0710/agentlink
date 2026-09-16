import 'package:companion/app_model.dart';
import 'package:companion/domain.dart';
import 'package:companion/hapi_api.dart';
import 'package:companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const one = SessionSummary(
  id: 'a',
  title: '修复登录',
  cwd: '/work/mobile',
  flavor: 'codex',
  active: true,
  updatedAt: 1,
);
const two = SessionSummary(
  id: 'b',
  title: '添加审批',
  cwd: '/work/mobile',
  flavor: 'codex',
  active: true,
  updatedAt: 2,
);

class UiApi extends HapiApi {
  UiApi() : super(Uri.parse('https://test.example'), 'test');
  @override
  Future<MessagePage> messagePage(
    String id, {
    int? beforeSeq,
    int? beforeAt,
  }) async => const MessagePage(messages: [], hasMore: false);
  @override
  Future<List<PendingRequest>> pending(String id) async => [];
}

class ApprovalModel extends AppModel {
  ApprovalModel() : super(persistState: false);
  Map<String, dynamic>? submitted;
  @override
  Future<void> decide(
    PendingRequest r,
    bool allow, {
    Map<String, dynamic>? answers,
  }) async {
    submitted = answers;
  }
}

void main() {
  testWidgets('input card submits nested multi-choice answers with a note', (
    tester,
  ) async {
    final model = ApprovalModel();
    const request = PendingRequest(
      id: 'r',
      sessionId: 's',
      tool: 'request_user_input',
      kind: 'input',
      args: {
        'questions': [
          {
            'id': 'features',
            'question': 'Choose features',
            'multiple': true,
            'options': [
              {'label': 'Chat'},
              {'label': 'Approve'},
            ],
          },
          {'id': 'optional', 'question': 'Optional', 'required': false},
        ],
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RequestCard(model: model, request: request),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Chat'));
    await tester.tap(find.text('Approve'));
    await tester.enterText(find.byType(TextFormField).first, 'Mobile first');
    await tester.pump();
    await tester.tap(find.text('提交回答'));
    expect(model.submitted, {
      'features': {
        'answers': ['Chat', 'Approve', 'user_note: Mobile first'],
      },
      'optional': {'answers': <String>[]},
    });
    model.dispose();
  });

  testWidgets('cold deep link and a queued distinct link each show once', (
    tester,
  ) async {
    const channel = MethodChannel('app.agentlink.companion/links');
    const first =
        'hapicompanion://bind?hub=https%3A%2F%2Ffirst.example&code=one';
    const second =
        'hapicompanion://bind?hub=https%3A%2F%2Fsecond.example&code=two';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'initialLink' ? first : null,
    );
    final model = AppModel(persistState: false);
    await tester.pumpWidget(AgentLink(model: model));
    await tester.pumpAndSettle();
    Future<void> deliver(String uri) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('link', uri)),
        (_) {},
      );
    }

    await deliver(
      first,
    ); // Duplicate cold/new-intent race must not queue itself.
    await deliver(second);
    await tester.pump();
    expect(find.textContaining('first.example'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.textContaining('second.example'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });
  testWidgets('pairing presents both providers and safe connection form', (
    tester,
  ) async {
    final model = AppModel(persistState: false);
    await tester.pumpWidget(AgentLink(model: model, receiveLinks: false));
    expect(find.text('连接你的电脑'), findsOneWidget);
    await tester.tap(find.text('扫码或手动连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接电脑'), findsOneWidget);
    // 扫码是主路径，手动填写作为备选并列出现；不再有装饰性的 Agent 标签。
    expect(find.text('扫码连接'), findsOneWidget);
    expect(find.text('或手动填写'), findsOneWidget);
    expect(find.text('电脑 Hub 的 HTTPS 地址'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets(
    '393px phone opens full-width chat, returns to grouped projects, isolates drafts',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(initialApi: UiApi(), persistState: false)
        ..sessions = [one, two];
      await tester.pumpWidget(AgentLink(model: model, receiveLinks: false));
      // 工作台只显示项目名，完整路径不再出现在列表里。
      expect(find.text('mobile'), findsOneWidget);
      expect(find.text('/work/mobile'), findsNothing);
      await tester.tap(find.text('mobile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修复登录'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Chat)).width, 393);
      expect(find.byType(Sessions), findsNothing);
      await tester.enterText(find.byType(TextField), 'only project A');
      await tester.tap(find.byTooltip('返回项目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加审批'));
      await tester.pumpAndSettle();
      expect(find.text('only project A'), findsNothing);
      await tester.tap(find.byTooltip('返回项目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修复登录'));
      await tester.pumpAndSettle();
      expect(find.text('only project A'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );

  testWidgets(
    'permission displays exact operation and locks submitted candidates',
    (tester) async {
      final model = AppModel(initialApi: UiApi(), persistState: false)
        ..sessions = [one]
        ..selectedSession = 'a'
        ..requests = [
          const PendingRequest(
            id: 'req',
            sessionId: 'a',
            tool: 'Write',
            kind: 'permission',
            args: {'path': '/work/mobile/file.txt'},
          ),
        ];
      model.submittedRequests.add('req');
      await tester.pumpWidget(AgentLink(model: model, receiveLinks: false));
      // 审批改成了弹出确认层。有请求时会自动弹出；若这次没赶上自动弹出，
      // 就点提示条手动打开 —— 两种路径都应当能进到同一个确认层。
      if (find.text('查看命令详情').evaluate().isEmpty) {
        await tester.tap(find.textContaining('项操作等待确认'));
        await tester.pumpAndSettle();
      }
      // 弹出层里命令详情默认收起，展开后才能核对具体操作。
      await tester.tap(find.text('查看命令详情').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('/work/mobile/file.txt'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '允许一次'),
      );
      expect(button.onPressed, isNull);
      expect(find.text('已提交，等待电脑确认'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );
}
