import 'package:companion/app_model.dart';
import 'package:companion/agentlink_theme.dart';
import 'package:companion/domain.dart';
import 'package:companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'app_model_test.dart' show FakeApi;

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('320px pairing remains scrollable at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(persistState: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: agentLinkTheme(),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 640),
              textScaler: TextScaler.linear(scale),
            ),
            child: Pairing(model),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
    testWidgets(
      '320px chat with approval and keyboard fits at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final model = AppModel(initialApi: FakeApi(), persistState: false)
          ..selectedSession = 'a'
          ..sessions = [
            const SessionSummary(
              id: 'a',
              title: '一个很长的任务标题用于验证窄屏显示和审批布局',
              cwd: '/work/mobile',
              flavor: 'codex',
              active: true,
              updatedAt: 1,
            ),
          ]
          ..requests = [
            const PendingRequest(
              id: 'r',
              sessionId: 'a',
              tool: 'Bash',
              kind: 'permission',
              args: {'command': 'flutter test', 'cwd': '/work/mobile'},
            ),
          ];
        await tester.pumpWidget(
          MaterialApp(
            theme: agentLinkTheme(),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 640),
                viewInsets: const EdgeInsets.only(bottom: 250),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(body: Chat(model)),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('发送'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
      },
    );
  }
}
