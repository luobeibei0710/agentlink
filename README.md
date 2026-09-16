# AgentLink

在 Android 手机上接管电脑上运行的 **Codex** 与 **CodeBuddy** 会话：浏览历史项目、查看对话、审批等待中的操作，并在需要时切换权限档位。

代码库同时包含电脑端的调度服务与 Android 客户端。

## 架构

```
┌─────────────────┐        ┌──────────────┐        ┌──────────────────────┐
│  Flutter App    │  ⇄     │     Hub      │  ⇄     │   Runner (macOS)     │
│  (Android)      │        │              │        │                      │
│  · 项目 / 会话   │        │  · 会话同步   │        │  ┌────────────────┐  │
│  · 对话渲染     │        │  · 权限路由   │        │  │ codex          │  │
│  · 审批卡片     │        │  · 设备配对   │        │  │ codebuddy --acp│  │
│  · 权限档位     │        │              │        │  └────────────────┘  │
└─────────────────┘        └──────────────┘        └──────────────────────┘
```

局域网模式由 `scripts/dev/agentlink-host.mjs` 同时拉起 Hub、Runner 与管理页：

| 服务 | 默认端口 | 说明 |
| --- | --- | --- |
| Hub | `3106` | REST API 与会话同步 |
| 设备 TLS | `3107` | 固定指纹的设备连接 |
| 局域网发现 | `3108` (UDP) | 广播发现电脑 |
| 本机管理页 | `3109` | 仅监听 `127.0.0.1`，用于核对配对数字与撤销设备 |

## 目录

| 目录 | 内容 |
| --- | --- |
| `flutter/` | Android 客户端（Dart） |
| `cli/` | Runner 与各 agent 适配，含 `cli/src/codebuddy/` |
| `hub/` | 会话同步中枢与 HTTP 路由 |
| `shared/` | 跨端协议、Schema 与权限档位定义 |
| `web/` | Web 客户端 |
| `scripts/dev/` | 局域网 Host、设备联调与冒烟脚本 |
| `docs/` | 需求、架构与逐轮验证记录 |
| `artifacts/` | 本地构建的 APK，**未纳入版本库** |

## 快速开始

### 电脑端

需要一个 Bun 运行时（`启动局域网连接.command` 会依次在 `~/.local/bin`、`~/.bun/bin`、Homebrew 路径下查找）：

```bash
curl -fsSL https://bun.sh/install | bash    # 或 npm install -g bun
```

然后**双击 `启动局域网连接.command`**，保持终端窗口打开。首次运行会打印配对二维码与管理页地址。

手动启动：

```bash
HAPI_BUN_BIN="$HOME/.local/bin/bun" node scripts/dev/agentlink-host.mjs --lan
```

### 手机端

```bash
cd flutter
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

安装后：

1. 手机与电脑连**同一个 Wi-Fi**；
2. 打开 App → 「扫码或手动连接」→ 扫电脑上的二维码；
3. 首次在电脑管理页核对 8 位数字后允许。

## 功能

**浏览**：`项目 → 会话 → 对话` 两段式下钻。工作台只显示项目名与状态点，会话列表每行只保留标题、状态与相对时间。

**对话**：Markdown（代码块带语言标签与复制）、工具卡片（输入输出可展开）、ChatGPT 风格的思考行（默认一行灰字、点击展开）、与 Web 端一致的用量状态行。

**审批**：待确认的操作按工具类型结构化展示 —— 命令类给命令行与工作目录，写入类给路径与改动行数，而不是把 JSON 参数直接铺在卡片上。命中 `rm -rf`、`sudo`、`git push --force` 等破坏性片段时会给出显式警示。

**用量与额度**：顶部「用量」入口按 `7 天 / 30 天 / 全部` 分别展示**本机消耗**与**历史累计**（两者口径不同，刻意不相加），并展示 Codex 的**账户额度** —— 套餐、各时间窗已用比例与重置时间。额度搭在消息流里下发，不额外轮询。

**公网连接**：除局域网外，可用 Cloudflare 隧道把电脑暴露到公网，手机不在同一 Wi-Fi 时也能用。见 [docs/public-host.md](docs/public-host.md)。

**权限档位**：按 agent 过滤可用档位，且**在会话运行中实时生效**（不需要重启 agent）。

| Agent | 档位 |
| --- | --- |
| Codex | 默认 / 只读 / 安全全自动 / 全自动 |
| CodeBuddy | 默认 / 自动接受编辑 / 计划模式 / 自动 / 不询问 / 跳过权限检查 / 完全访问 / 由父会话管理 |
| Claude / Cursor / Copilot | 见 `shared/src/modes.ts` |

档位显示的是**电脑端上报的真实值**（`SessionSummary.permissionMode`），不是手机本地猜测。

## 已知限制

- **自动发现（UDP 广播）在部分路由器或机型上不通** —— 表现为「附近的电脑」扫不到。遇到时用扫码配对，这是可靠路径。
- **Cloudflare 快速隧道的随机域名在国内 DNS 上有同步延迟** —— 刚建立时可能十几分钟到一小时解析不到，且隧道一关记录立即撤销。长期使用请换固定域名，见 [docs/public-host.md](docs/public-host.md)。
- **额度只覆盖 Codex** —— CodeBuddy 的 ACP 协议不下发额度，本仓库也未实现其 `/v2/billing/*` 端点。
- **不提供后台推送**。App 在前台每 2 秒同步；退到后台不会收到提醒。
- **CodeBuddy IDE 的历史对话正文拿不到** —— 它存在云端，本地只有指针。IDE 项目会作为项目分组出现，但正文仅覆盖 CodeBuddy CLI 会话。
- **仅支持 Android**。
- 代码 Diff 视图、Mermaid / KaTeX 渲染尚未对齐 Web 端。

## 开发

```bash
# 手机端
cd flutter
flutter analyze
flutter test                    # 含渲染快照，见 test/goldens/

# 电脑端
bun run typecheck
bun run test:cli
```

渲染快照覆盖了对话、项目列表、会话列表、配对页、设备页与审批卡片。更新快照前请先确认差异是预期的：

```bash
flutter test --update-goldens
```

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/agentlink-flutter.md](docs/agentlink-flutter.md) | 客户端架构、渲染对齐、UI 信息架构、权限模式与审批卡片 |
| [docs/agentlink-validation.md](docs/agentlink-validation.md) | 1.0.0 真实联调记录 |
| [docs/agentlink-ui-validation.md](docs/agentlink-ui-validation.md) | 1.1.0 界面改版的验收 |
| [docs/agentlink-device-validation.md](docs/agentlink-device-validation.md) | 1.3.0 真机验收清单 |
| [docs/agentlink-lan-validation.md](docs/agentlink-lan-validation.md) | 局域网模式验证 |
| [docs/lan-host.md](docs/lan-host.md) | 电脑端局域网 Host 说明 |
| [docs/public-host.md](docs/public-host.md) | 公网连接：Cloudflare 隧道、固定域名与已知的 DNS 同步问题 |

## 许可

见 [LICENSE](LICENSE)。
