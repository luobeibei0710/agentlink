# AgentLink 1.1.0：Flutter 页面实施与验收

日期：2026-09-13。此页是当前交付；[1.0.0 验证记录](agentlink-validation.md)仅保留历史证据。未提交、推送或发布应用商店。

## 交付

- [Android 测试安装包](../artifacts/agentlink/AgentLink-1.1.0-android.apk)，版本 `1.1.0+2`，包名 `app.agentlink.companion`，约 50.8 MB。
- SHA-256：`980d1ac18b678b1a2079212438de26a3b36d2030177fe1fe3575df0a122dc0fc`。
- Release 优化构建，当前使用 Android Debug 证书签名，供本次测试，不是商店发行签名。
- [Figma 设计稿](https://www.figma.com/design/D8u9JqxEJfewO1TdOzmxys/AgentLink-Flutter-Android)。界面采用响应式 Flutter 实现，审批与问题表单嵌入对话，保留完整操作参数；并非逐像素固定画板。

## 实现范围

配对页、Codex/CodeBuddy 选择、项目卡与项目内进行中/历史任务、待处理聚合、创建任务与初始描述、聊天与工具记录、一次审批/拒绝、结构化回答、连接与未确认消息恢复均接入现有 AppModel。底部导航与宽屏侧栏可访问相同功能；保留重命名、停止、取消排队、恢复历史会话及更早消息加载。

执行中取自服务端 `thinking`，在线取自 `active`，避免将在线空闲任务标成正在执行。待处理列表取自实际 session summary，点击后重新读取权威请求再决定。

## 审查修复

- 新建任务使用明确 Agent 和返回 session ID；取消弹窗不改变当前 Agent，初始描述先绑定新会话草稿。
- 安全存储失败恢复草稿；认证失效、错误重配和重启均保留对应 Hub 的草稿及未确认消息。错误配对候选不删除当前有效凭据。
- 跨会话恢复页展示完整的当前 Hub 未确认队列；重试仍沿用原 localId。
- “忘记此 Hub”先明确确认本机会清除的内容，和暂时网络中断区分。
- `AskUserQuestion` 补充文字不再被静默丢弃；小写工具名正确进入输入表单；不支持的 Cursor 输入格式无法误作普通工具授权。
- 跨 Agent 待处理跳转保持 Agent 上下文；异步返回检查 mounted。
- 项目下钻支持 Android 系统返回，宽屏对话有可见返回入口；加载历史保留阅读位置。
- 修复 320px、200% 字体与键盘下的溢出，以及浮动新会话按钮遮挡底部导航。

## 本次实际验证

| 验证 | 结果 |
| --- | --- |
| `flutter analyze` | 无问题 |
| `flutter test --reporter expanded` | 44 项通过 |
| `flutter build apk --release --build-name=1.1.0 --build-number=2` | 成功 |
| APK 版本及签名 | aapt 确认 1.1.0 / 2；apksigner 校验成功 |
| 独立终审 | Sol 定点复核修复与最终 APK，未发现剩余 P1/P2 |
| 专用模拟器 | 最终交付 APK 安装成功，`LaunchState: COLD` / `Status: ok`，版本 1.1.0 / 2，实际显示配对页且没有演示标识；未操作物理手机 |
| 页面交互 | 标记“演示数据”的独立调试入口检查项目、待处理、跨 Agent 会话、审批按钮与返回对话 |
| 新版真实跨设备联网 | 本轮未完成：HAPI relay 等待可信证书；备用隧道出现 TLS/连接错误 |

模拟器中的演示审批不会执行真实电脑命令。此前 1.0.0 的真实 Hub/Runner/Codex/CodeBuddy 联调保留在历史报告，本次不将历史结果冒充新版联网验收。没有绕过 HTTPS 或证书校验。

当前安装包仍需可用的 HTTPS Hub；[Host 启动说明](agentlink-flutter.md)。实际用户真机测试留给用户：配对、项目与 Agent 切换、发送和停止、有效审批、断网恢复、重启草稿与重复发送防护。

## 证据与复现

- [测试日志](../artifacts/agentlink/flutter-ui-tests.log)、[静态检查](../artifacts/agentlink/flutter-ui-analyze.log)、[构建日志](../artifacts/agentlink/flutter-ui-build.log)。
- [Release 配对页](../artifacts/agentlink/ui-release-pairing.png)。
- 演示数据截图：[项目](../artifacts/agentlink/ui-preview-projects.png)、[审批](../artifacts/agentlink/ui-preview-approval.png)、[对话](../artifacts/agentlink/ui-preview-chat.png)。
- `flutter/tool/design_preview.dart` 是单独的 UI 演示入口，使用内存 fixture；不被 `lib/main.dart` 或交付 Release 构建引用。复现命令：`flutter run -d emulator-5580 -t tool/design_preview.dart --debug`。
