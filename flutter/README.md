# AgentLink Flutter Android

独立 Flutter 客户端，直接连接 HAPI REST API。支持 Codex / CodeBuddy 切换、项目路径分组、历史对话、标题、发送和重试、排队取消、执行停止、输入与权限审批、历史会话恢复。

完整启动说明、实际范围和手机验收步骤见 [使用说明](../docs/agentlink-flutter.md)，验证结果见 [验证记录](../docs/agentlink-validation.md)。

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

默认使用 HTTPS 配对；受信任局域网也可按 [电脑局域网 Host](../docs/lan-host.md) 使用 `--lan` 配对。连接凭据、会话草稿和待发送记录存入系统安全存储；JWT 仅驻留内存。前台每 2 秒同步，后台不提供推送保证。网络异常后的显式重试复用原消息 ID；审批以电脑最终裁决为准。
