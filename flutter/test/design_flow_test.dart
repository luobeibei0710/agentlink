import 'package:companion/app_model.dart';
import 'package:companion/domain.dart';
import 'package:companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'app_model_test.dart' show FakeApi, MemoryStorage;

const codexTask = SessionSummary(
  id: 'a',
  title: '连接流程',
  cwd: '/work/mobile',
  flavor: 'codex',
  active: true,
  updatedAt: 1,
);
const buddyTask = SessionSummary(
  id: 'b',
  title: '审批任务',
  cwd: '/work/buddy',
  flavor: 'codebuddy',
  active: true,
  pending: 1,
  updatedAt: 2,
);

class DesignApi extends FakeApi {
  DesignApi() {
    sessionRows = [codexTask, buddyTask];
  }
  String? spawnedAgent;
  @override
  Future<List<Machine>> machines() async => [
    const Machine(id: 'host', name: 'Test Host', active: true),
  ];
  @override
  Future<List<AgentAvailability>> agentAvailability(String machine) async => [
    const AgentAvailability(agent: 'codex', available: true),
    const AgentAvailability(agent: 'codebuddy', available: true),
  ];
  @override
  Future<String> spawn(String machine, String path, String agent) async {
    spawnedAgent = agent;
    sessionRows = [
      ...sessionRows,
      SessionSummary(
        id: 'new',
        title: '新建任务',
        cwd: path,
        flavor: agent,
        active: true,
        updatedAt: 3,
      ),
    ];
    return 'new';
  }
}

void main() {
  void phone(WidgetTester tester, {double width = 393}) {
    tester.view.physicalSize = Size(width, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('project drilldown and system back restore workspace', (
    tester,
  ) async {
    phone(tester);
    final api = DesignApi();
    final model = AppModel(initialApi: api, persistState: false)
      ..sessions = api.sessionRows;
    await tester.pumpWidget(AgentLink(model: model, receiveLinks: false));
    expect(
      tester.getRect(find.byType(FloatingActionButton)).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(NavigationBar)).top),
    );
    await tester.tap(find.text('mobile'));
    await tester.pumpAndSettle();
    expect(find.byType(Sessions), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Projects), findsOneWidget);
    expect(find.byType(Sessions), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
  testWidgets(
    'cross-provider pending opens its owner and wide chat can return',
    (tester) async {
      phone(tester, width: 1000);
      final api = DesignApi();
      final model = AppModel(initialApi: api, persistState: false)
        ..sessions = api.sessionRows;
      await tester.pumpWidget(AgentLink(model: model, receiveLinks: false));
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('审批任务'));
      await tester.pumpAndSettle();
      expect(model.selectedAgent, 'codebuddy');
      expect(model.selectedSession, 'b');
      await tester.tap(find.byTooltip('返回项目'));
      await tester.pumpAndSettle();
      expect(find.byType(Projects), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );
  testWidgets('cancelled new task does not change provider or active chat', (
    tester,
  ) async {
    phone(tester);
    final api = DesignApi();
    final model = AppModel(initialApi: api, persistState: false)
      ..sessions = api.sessionRows
      ..machines = await api.machines()
      ..selectedSession = 'a';
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: NewSessionDialog(model))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('CodeBuddy'));
    await tester.pumpAndSettle();
    expect(model.selectedAgent, 'codex');
    expect(model.selectedSession, 'a');
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
  testWidgets('unsupported input from wire cannot become a tool approval', (
    tester,
  ) async {
    phone(tester);
    final model = AppModel(persistState: false);
    final request = PendingRequest.fromEntry('a', 'r', {
      'tool': 'CursorAskQuestion',
      'arguments': {
        'questions': [
          {
            'id': 'q',
            'prompt': 'Choose',
            'options': [
              {'id': 'x', 'label': 'X'},
            ],
          },
        ],
      },
    });
    expect(request.needsAnswer, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RequestCard(model: model, request: request),
        ),
      ),
    );
    expect(find.text('允许一次'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
  testWidgets(
    'storage failure preserves initial task description in its new draft',
    (tester) async {
      phone(tester);
      final api = DesignApi();
      final storage = MemoryStorage()..failWrites = true;
      final model = AppModel(initialApi: api, storage: storage)
        ..sessions = api.sessionRows
        ..machines = await api.machines();
      await tester.pumpWidget(AgentLink(model: model, receiveLinks: false));
      await tester.tap(find.text('新会话'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.last, '不要丢失这个需求');
      await tester.tap(find.textContaining('创建并开始'));
      await tester.pumpAndSettle();
      expect(model.selectedSession, 'new');
      expect(model.draftFor('new'), '不要丢失这个需求');
      expect(api.sent, isEmpty);
      expect(find.text('不要丢失这个需求'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );
}
