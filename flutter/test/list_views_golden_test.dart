import 'package:companion/agentlink_theme.dart';
import 'package:companion/app_model.dart';
import 'package:companion/domain.dart';
import 'package:companion/hapi_api.dart';
import 'package:companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只提供会话目录的替身，让快照测试不触碰网络。
class _StubApi extends HapiApi {
  _StubApi(this.rows) : super(Uri.parse('https://hub.example'), 'token');

  final List<SessionSummary> rows;

  @override
  Future<Map<String, dynamic>> health() async => {
    'status': 'ok',
    'protocolVersion': 1,
  };
  @override
  Future<void> authenticate() async {}
  @override
  Future<List<SessionSummary>> sessions() async => rows;
  @override
  Future<List<Machine>> machines() async => const [];
  @override
  void close() {}
}

const _project = '/Users/llvision/Desktop/商业化项目/hapi-codebuddy-android';

/// 相对当前时间构造会话，使相对时间文案在每次运行中保持恒定。
SessionSummary _session({
  required String id,
  required String title,
  required bool active,
  bool thinking = false,
  int pending = 0,
  int minutesAgo = 2,
  String cwd = _project,
}) => SessionSummary(
  id: id,
  title: title,
  cwd: cwd,
  flavor: 'codex',
  active: active,
  thinking: thinking,
  pending: pending,
  updatedAt: DateTime.now().millisecondsSinceEpoch - minutesAgo * 60000,
);

Future<AppModel> _pairedModel(List<SessionSummary> rows) async {
  final model = AppModel(
    apiFactory: (_, _) => _StubApi(rows),
    persistState: false,
  );
  await model.pair('hub.example', 'token');
  return model;
}

Future<void> _pump(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: agentLinkTheme(), home: Scaffold(body: body)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the project list without nested session buttons', (
    tester,
  ) async {
    final model = await _pairedModel([
      // 有待确认的项目：状态点与汇总行都应体现出来。
      _session(id: 'a1', title: '修复登录页崩溃', active: true, pending: 2),
      _session(id: 'a2', title: '重构支付模块', active: true, thinking: true),
      _session(id: 'a3', title: '整理构建脚本', active: false, minutesAgo: 90),
      // 另一个项目，展示「已结束」的弱化状态。
      _session(
        id: 'b1',
        title: '接入埋点',
        active: false,
        minutesAgo: 60 * 30,
        cwd: '/Users/llvision/Desktop/slim-glass-app',
      ),
    ]);

    await _pump(
      tester,
      Projects(model: model, onOpen: (_) {}, onPending: () {}),
    );

    await expectLater(
      find.byType(Projects),
      matchesGoldenFile('goldens/projects.png'),
    );
    model.dispose();
  });

  testWidgets('renders the session list as one line per session', (
    tester,
  ) async {
    final model = await _pairedModel([
      _session(id: 'a1', title: '修复登录页崩溃', active: true, pending: 3),
      _session(id: 'a2', title: '重构支付模块的状态管理', active: true, thinking: true),
      _session(id: 'a3', title: '整理构建脚本与签名配置', active: false, minutesAgo: 90),
      _session(id: 'a4', title: '接入埋点', active: false, minutesAgo: 60 * 30),
    ]);

    await _pump(
      tester,
      Sessions(model, projectPath: _project),
    );

    // 默认展示「进行中」，只有活跃会话。
    await expectLater(
      find.byType(Sessions),
      matchesGoldenFile('goldens/sessions.png'),
    );

    // 切到「已结束」应换成历史会话。
    await tester.tap(find.textContaining('已结束'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Sessions),
      matchesGoldenFile('goldens/sessions_history.png'),
    );
    model.dispose();
  });
}
