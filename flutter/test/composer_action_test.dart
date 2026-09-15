import 'package:companion/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('composer button follows the session state machine', () {
    // 正在执行：主按钮变成停止，避免误发新消息。
    expect(
      resolveComposerAction(active: true, thinking: true),
      ChatComposerAction.stop,
    );

    // 空闲在线：可以发送。
    expect(
      resolveComposerAction(active: true, thinking: false),
      ChatComposerAction.send,
    );

    // 会话已结束：先恢复会话才能继续输入。
    expect(
      resolveComposerAction(active: false, thinking: false),
      ChatComposerAction.resume,
    );

    // 仍在执行时停止优先：状态不一致时宁可让用户中断，也不要放进新消息。
    expect(
      resolveComposerAction(active: false, thinking: true),
      ChatComposerAction.stop,
    );
  });
}
