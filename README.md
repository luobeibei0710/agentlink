# AgentLink

在 Android 手机上接管电脑上运行的 **Codex** 与 **CodeBuddy** 会话：浏览历史项目、查看对话、审批等待中的操作，并在需要时切换权限档位。

代码库同时包含电脑端的调度服务与 Android 客户端。

> **本项目基于 [tiann/hapi](https://github.com/tiann/hapi) 构建**，沿用其 AGPL-3.0 许可。
> Hub、Runner、跨端协议与 Web 客户端的主体来自上游；AgentLink 在其之上加入了 Android
> 客户端、CodeBuddy 适配、公网 Host、用量与额度等能力，详见
> [与原版 hapi 的关系](#与原版-hapi-的关系)。

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

## 与原版 hapi 的关系

上游 [hapi](https://github.com/tiann/hapi) 解决的是「在浏览器里接管 Codex 会话」；AgentLink 把它延伸到手机上，并补齐了若干上游没有的部分。分清边界对二次开发很重要：

**来自上游**：Hub 的会话同步与权限路由、Runner、ACP / Codex 适配、跨端协议（`shared/`）、Web 客户端（`web/`）。

**本项目新增或改动较大**：

| 方向 | 内容 | 位置 |
| --- | --- | --- |
| Android 客户端 | 上游只有 iOS 原生与 Web；项目、会话、对话、审批、权限档位、模型切换、用量与额度都在这里 | `flutter/` |
| CodeBuddy 适配 | 走其 ACP 协议接入，含 8 档权限模式与运行中切换模型。**未复制 Octop 代码** | `cli/src/codebuddy/` |
| 公网 Host | 用 Cloudflare 隧道替代官方 relay，一键起隧道并生成配对码 | `scripts/dev/agentlink-public.mjs` |
| 用量与额度 | Hub 侧用量汇总（本机消耗与导入历史分开）、Codex 账户额度的端到端透传 | `hub/src/sync/usageService.ts` |
| 会话恢复 | 导入的历史会话在电脑上没有进程，发送时自动恢复，不必先手动「继续」 | `flutter/lib/app_model.dart` |

## 系统要求

| | 要求 |
| --- | --- |
| 电脑 | **macOS** —— Runner 目前只实现了 macOS |
| 运行时 | [Bun](https://bun.sh) 1.4+（`启动局域网连接.command` 会自动查找） |
| 已登录的 CLI | `codex`、`codebuddy` —— Hub 通过它们的 app-server / ACP 接口驱动会话 |
| 手机 | Android 7.0（API 24）及以上 |
| 构建客户端 | Flutter（Dart SDK 3.11.5+） |

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

**会话交互**：导入的历史会话在电脑上没有进程，**不需要先手动点「继续」** —— 直接输入并发送，会自动恢复会话再投递；启动期间按钮转圈、头部显示「正在启动…」，轮询间隔临时从 2 秒缩到 600 毫秒，状态变化不必干等。恢复失败则不发送，避免消息落到已归档的会话上。

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

**模型切换**：会话内可切换模型。列表同样取自电脑端 —— Codex 走 RPC 查询，CodeBuddy 取该会话的 ACP 配置选项，因此不会出现「列了但切不了」的假选项。

## 已知限制

- **自动发现（UDP 广播）在部分路由器或机型上不通** —— 表现为「附近的电脑」扫不到。遇到时用扫码配对，这是可靠路径。
- **Cloudflare 快速隧道的随机域名在国内 DNS 上有同步延迟** —— 刚建立时可能十几分钟到一小时解析不到，且隧道一关记录立即撤销。长期使用请换固定域名，见 [docs/public-host.md](docs/public-host.md)。
- **额度只覆盖 Codex** —— CodeBuddy 的 ACP 协议不下发额度，本仓库也未实现其 `/v2/billing/*` 端点。
- **不提供后台推送**。App 在前台每 2 秒同步；退到后台不会收到提醒。
- **CodeBuddy IDE 的历史对话正文拿不到** —— 它存在云端，本地只有指针。IDE 项目会作为项目分组出现，但正文仅覆盖 CodeBuddy CLI 会话。
- **仅支持 Android**。
- 代码 Diff 视图、Mermaid / KaTeX 渲染尚未对齐 Web 端。

## 常见问题

**手机上「附近的电脑」扫不到** —— 自动发现走 UDP 广播，部分路由器或机型会拦。改用二维码配对。

**配对后连不上** —— 电脑侧的 Hub 必须一直运行（前台终端别关）。局域网模式下手机与电脑要在同一个 Wi-Fi，且路由器没开 AP 隔离。

**公网地址在电脑上打不开、手机却能用** —— 这不是配置错误：Cloudflare 快速隧道的随机域名在国内 DNS 上有同步延迟（十几分钟到一小时），手机走运营商 DNS 通常不受影响。详见 [docs/public-host.md](docs/public-host.md)。

**看不到额度** —— 额度只有 Codex 有，且要等 Hub 跑过一次带额度的会话：它是搭在消息流里下发的，不会凭空出现。

**历史会话进去就能发消息吗** —— 能。导入的会话在电脑上没有进程，发送时会自动恢复，不必先点「继续」。

## 版本

当前客户端 **1.12.0**（`versionCode 15`），由 `flutter/pubspec.yaml` 的 `version` 字段决定，构建时不需要再传 `--build-name`：

```bash
cd flutter && flutter build apk --release   # → 1.12.0+15
```

`shared/src/buildInfo.ts` 里的 `0.30.3` 是**上游 hapi 的版本号**，用于定位 `~/.agentlink/runtime/<version>` 下的运行时目录 —— **不要跟着客户端一起改**，否则会找不到已下载的运行时。

`docs/` 下的 `*-validation.md` 是各里程碑的逐轮验收记录，按当时的编号，不随客户端版本回填。

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

## 来源与许可

基于 [tiann/hapi](https://github.com/tiann/hapi)，遵循仓库 [AGPL-3.0](LICENSE) 许可。

AGPL-3.0 具有传染性：分发本项目的修改版（**包括以网络服务形式对外提供**）时，需要一并提供对应源码与许可声明。CodeBuddy 接入是基于其 ACP 协议的独立实现，没有复制 Octop 源代码。
