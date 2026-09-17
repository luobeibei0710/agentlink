@Tags(['golden'])
library;

import 'package:companion/agentlink_theme.dart';
import 'package:companion/app_model.dart';
import 'package:companion/domain.dart';
import 'package:companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders approval cards for command, file, and network tools', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final model = AppModel(persistState: false);
    final requests = [
      // 破坏性命令：应出现危险提示。
      PendingRequest(
        id: '1',
        tool: 'Bash',
        kind: 'permission',
        args: {
          'command': 'rm -rf node_modules && npm install',
          'cwd': '/work/demo-app',
        },
      ),
      // 写文件：路径 + 改动行数。
      PendingRequest(
        id: '2',
        tool: 'Write',
        kind: 'permission',
        args: {
          'file_path': '/work/demo-app/lib/main.dart',
          'content': List.filled(42, 'line').join('\n'),
        },
      ),
      PendingRequest(
        id: '3',
        tool: 'WebFetch',
        kind: 'permission',
        args: {'url': 'https://example.com/spec'},
      ),
      // 未知工具：退化成键值对而不是裸 JSON。
      PendingRequest(
        id: '4',
        tool: 'Mystery',
        kind: 'permission',
        args: {'alpha': 1, 'beta': 'two'},
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: agentLinkTheme(),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(AgentLinkSpace.lg),
            children: [
              for (final request in requests)
                Padding(
                  padding: const EdgeInsets.only(bottom: AgentLinkSpace.md),
                  child: RequestCard(model: model, request: request),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 命令详情默认收起，快照记录的是折叠态 —— 这是用户实际看到的默认形态。
    await expectLater(
      find.byType(ListView),
      matchesGoldenFile('goldens/approval_cards.png'),
    );

    // 再断言展开后仍能读到具体操作：折叠不能把渲染问题一起藏起来。
    await tester.ensureVisible(find.text('查看命令详情').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看命令详情').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('rm -rf node_modules'), findsOneWidget);
    model.dispose();
  });
}
