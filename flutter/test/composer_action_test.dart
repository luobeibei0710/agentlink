import 'package:companion/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('composer button only switches to stop while the agent is running', () {
    // 执行中：主按钮变成停止，避免误发新消息。
    expect(resolveComposerAction(thinking: true), ChatComposerAction.stop);

    // 其余情况一律是发送。历史会话离线时也直接发送 —— 发送会先自动恢复会话，
    // 所以不存在单独的「恢复」形态（早期版本要求用户先点一次「继续」）。
    expect(resolveComposerAction(thinking: false), ChatComposerAction.send);
  });
}
