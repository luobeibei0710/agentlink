import 'package:companion/agentlink_theme.dart';
import 'package:companion/domain.dart';
import 'package:companion/message_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一条带展示形态的消息，仅用于渲染快照。
ChatMessage message({
  required String id,
  required MessageView view,
  String text = '',
  String toolName = '',
  Object? toolInput,
  Object? toolOutput,
  bool toolFailed = false,
  String statusIcon = '',
  String? callId,
}) => ChatMessage(
  id: id,
  localId: id,
  role: view == MessageView.user ? 'user' : 'agent',
  view: view,
  text: text,
  createdAt: 0,
  toolName: toolName,
  toolInput: toolInput,
  toolOutput: toolOutput,
  toolFailed: toolFailed,
  statusIcon: statusIcon,
  callId: callId,
);

void main() {
  testWidgets('renders every message view inside a phone-width chat', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final entries = <ChatEntry>[
      ChatEntry(
        message(
          id: 'u1',
          view: MessageView.user,
          text: 'Check the build and report the failing step.',
        ),
      ),
      ChatEntry(
        message(
          id: 'a1',
          view: MessageView.agentText,
          text:
              '## Build result\n\nThe **release** build failed.\n\n'
              '1. Gradle task `assembleRelease`\n2. Missing signing config\n\n'
              '> Fix the keystore path first.\n\n'
              '```kotlin\nandroid {\n    signingConfig = debug\n}\n```',
        ),
      ),
      ChatEntry(
        message(
          id: 't1',
          view: MessageView.toolCall,
          text: 'Read',
          toolName: 'Read',
          callId: 'call-1',
          toolInput: {'path': 'flutter/android/app/build.gradle.kts'},
        ),
        result: message(
          id: 't1r',
          view: MessageView.toolResult,
          callId: 'call-1',
          toolOutput: 'android {\n    compileSdk = 36\n}',
        ),
      ),
      ChatEntry(
        message(
          id: 't2',
          view: MessageView.toolCall,
          text: 'Bash',
          toolName: 'Bash',
          callId: 'call-2',
          toolInput: {'command': './gradlew assembleRelease'},
        ),
        result: message(
          id: 't2r',
          view: MessageView.toolResult,
          callId: 'call-2',
          toolFailed: true,
          toolOutput: 'FAILURE: Build failed with an exception.',
        ),
      ),
      ChatEntry(
        message(
          id: 'r1',
          view: MessageView.reasoning,
          text: 'Checking outputs.',
        ),
        reasoningDurationMs: 12000,
      ),
      ChatEntry(
        message(
          id: 's1',
          view: MessageView.status,
          text: 'Context 12.0k / 200.0k (6%) · out 2k · cached 3k',
          statusIcon: '◷',
        ),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: agentLinkTheme(),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final entry in entries)
                Align(
                  alignment: entry.message.view == MessageView.user
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: switch (entry.message.view) {
                      MessageView.status => StatusLine(
                        text: entry.message.text,
                        icon: entry.message.statusIcon,
                      ),
                      MessageView.reasoning => ReasoningPanel(
                        entry.message.text,
                        durationMs: entry.reasoningDurationMs,
                      ),
                      MessageView.toolCall || MessageView.toolResult =>
                        ToolCallCard(
                          message: entry.message,
                          result: entry.result,
                        ),
                      _ => Card(
                        color: entry.message.view == MessageView.user
                            ? AgentLinkColors.lavender
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: AgentMarkdown(entry.message.text),
                        ),
                      ),
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(ListView),
      matchesGoldenFile('goldens/message_views.png'),
    );
  });
}
