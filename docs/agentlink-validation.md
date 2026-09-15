# AgentLink 1.0.0 历史验证记录

本页保留 UI 改版前的测试与安装证据，不是最新交付。新版见 [1.1.0 UI 实施与验收](agentlink-ui-validation.md)。

日期：2026-09-13。基础版本：HAPI `95b06bd502b44e906fb12c57c3824d42f091019c`。工作分支：`feature/flutter-codebuddy-companion`。尚未提交或发布。

## 实际完成的验证

| 层次 | 结果 |
| --- | --- |
| HAPI CLI 全量测试 | 2783 通过，7 跳过；随后新增的就绪信号、metadata ACK 和重复字符回归用例分别通过 |
| Hub 全量测试 | 1290 通过，3 跳过 |
| Web 全量测试 | 3072 通过 |
| Shared 全量测试 | 325 通过 |
| Relay 全量测试 | 118 通过 |
| CLI / Hub / Web / Relay TypeScript 检查 | 全部通过 |
| Flutter 静态检查 | 无问题 |
| Flutter 自动化测试 | 33 通过，含同 ID 恢复保留草稿回归 |
| Android 构建 | Debug 与 Release APK 已构建；最终 Release 安装验证见下方交付记录 |
| 独立审查 | Sol 终审未发现剩余 Critical / High 阻断问题 |
| 用户 Android 真机 | 未执行，交由用户 |

真实 CodeBuddy ACP 直连验证了 initialize、session/new、真实回复、拒绝和允许工具请求。实际 HAPI Hub → Runner → CodeBuddy/Codex 联调共 10 项通过：

1. Hub health、认证和未授权隔离。
2. Runner 注册和代理可用性。
3. CodeBuddy 创建、真实回复、相同 localId 去重。
4. 标题改名及正确 provider 元数据。
5. Flutter 自身 HTTP 客户端认证、发消息、解析真实 CodeBuddy 回复。
6. 拒绝文件操作，文件未生成，重复审批返回过期。
7. 允许文件操作，文件确实生成，重复审批返回过期。
8. 停止等待审批的执行，文件未生成。
9. CodeBuddy 归档、加载原生历史、继续获得真实回复。
10. Codex 真实回复及两类会话隔离。

该联调使用临时工作区和已登录的真实代理，不是 mock agent。脚本为 `scripts/dev/agentlink-live-smoke.mjs`，结果日志在本机 `/tmp/agentlink-live-final.log`。临时测试 token 未写入交付文档。

独立模拟器 `AgentLink_QA_API36` / `emulator-5580` 已验证：安装、冷启动配对链接唤起、确认目标 Hub、真实 HTTPS 认证、项目分组、Codex/CodeBuddy 切换、读取真实对话、展示带完整文件路径及内容的审批、点击允许后电脑实际生成 `AGENTLINK_OK` 文件。未使用用户已有 MuMu，也未操作物理手机。

## 审查与联调修复

- CodeBuddy ACP 标准权限入口、禁止覆盖为跳过审批模式。
- 恢复历史在 ACP 加载和 metadata ACK 后发送真正的 `session-ready` 信号。
- CodeBuddy 文本采用 delta 模式，保留重复字符，修复 FLUTTER 被错误去重为 FLUTER。
- Flutter 消息使用真实角色包装结构，过滤 token/lifecycle 内部事件，保留工具参数。
- 使用 after 光标增量追赶并保留已加载历史；会话和连接切换后丢弃过期响应。
- 配对状态以单个加密记录保存；待发消息先持久化再提交，显式重试沿用原 ID。
- 审批绑定会话、请求 ID 和当前权威状态；提交不代表最终获准。
- AskUserQuestion 与 request_user_input 使用各自正确的答案结构。
- 手机全宽对话、项目分组、独立草稿、输入请求控件和深链冷启动/排队处理。
- 修复中文目录造成的 tunwg 下载路径和 Relay 测试 URL 解码错误。

## 最终安装包

交付文件：`artifacts/agentlink/AgentLink-1.0.0-android.apk`，约 50.5 MB，包名 `app.agentlink.companion`，版本 `1.0.0+1`，最低 Android 7.0 / API 24，目标 API 36。APK v2 签名校验通过。

SHA-256：`b5070088db4e60218a51bc04902beb5809273b5521c106358c00eb8a99261d69`。

最终 Release APK 已覆盖安装到独立模拟器并强制停止后重开，安全存储中的配对信息恢复成功。测试中实际遇到 HAPI 公共 relay TLS 握手短暂中断：本机 Hub 持续返回 200，App 保留连接并显示网络错误，随后轮询恢复会话列表。公网 relay 的可达性依赖用户网络，不保证持续稳定；需要稳定部署时可使用自有 HTTPS 地址。

最终 Release App 的发送与重试也已实测：隧道恢复后点击原消息的重试按钮，Hub 只记录一条用户消息（原 `localId` 保持不变），Codex 返回 `AGENTLINK_PHONE_READY`，客户端读取并显示回复。该项是在模拟器 App UI 上操作，不是仅调用 API。

证据文件位于 `artifacts/agentlink/`：`live-integration.log`、`flutter-tests.log`、`release-projects.png`、`release-chat.png`、`emulator-approval-before.png` 和 `emulator-approval-after.png`。其中权限截图来自先前 Debug 安装，Release 截图来自最终交付 APK。

## 验证边界

本版本面向文本对话、工具执行记录和审批，不宣称实现完整 HAPI 客户端的附件、图片、代码 diff/review 或所有 golden fixture 视图。CodeBuddy IDE 内既有全部会话的枚举与接管未实现；控制对象是通过本 Host 运行和恢复的 CLI / ACP 会话。

App 使用前台轮询，不含后台推送保证。安装包用于侧载验收，release 优化构建仍使用本机开发签名，不能直接作为应用商店正式发布包。

真机需检查扫码唤起、中文键盘、前后台切换、进程重启、网络变化和实际电脑任务。构建与模拟器通过不等同于真机验收通过。
