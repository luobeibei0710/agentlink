# AgentLink：Flutter Android + HAPI + CodeBuddy / Codex

AgentLink 是独立 Flutter Android 客户端，电脑端使用本仓库的 HAPI Hub、Runner 和 CodeBuddy ACP 适配器。Android 源码在 `flutter/`；上游 `android/` Kotlin 客户端不作为本次交付客户端。

## 启动电脑端

电脑需要已登录的 `codebuddy` 和 `codex` 命令。本次验证使用 macOS、CodeBuddy 2.132.0、Codex 0.154.0-alpha.6.2、Bun 1.4.0。不要使用未经修改的全局 HAPI 替代本仓库，否则没有新增的 CodeBuddy provider。

在仓库目录运行：

```sh
npm exec --yes --package=bun@1.4.0 -- bun install --frozen-lockfile --registry https://registry.npmjs.org
npm exec --yes --package=bun@1.4.0 -- bun run download:tunwg
npm exec --yes --package=bun@1.4.0 -- bun scripts/dev/agentlink-host.mjs '/你的项目完整路径'
```

保留终端运行。Host 默认端口 3106、状态目录 `~/.agentlink`，通过 HAPI relay 提供受信任的 HTTPS 地址。复制终端显示的 HTTPS Hub 地址和配对码到手机，或用 Android 系统相机扫描 `hapicompanion://bind` 二维码后选择 AgentLink。也可在 App 中粘贴终端的 Web 配对链接。配对码具有访问电脑会话的权限，不要公开转发。

`AGENTLINK_HOME` 和 `AGENTLINK_PORT` 可覆盖隔离状态目录及端口。默认 relay 使用 HTTPS；受信任局域网可使用 [电脑局域网 Host](lan-host.md) 的 `--lan` 配对。`AGENTLINK_NO_RELAY=1` 仅供本机 API 调试；手机客户端要求 HTTPS 时需要自行提供受信任的 HTTPS 反向代理。`HAPI_CODEBUDDY_ACP_COMMAND` 可指定 CodeBuddy 可执行文件完整路径。

## 手机使用

1. 安装交付的 APK，首次连接电脑。
2. 在 Codex / CodeBuddy 间切换，按电脑项目路径查看会话分组。
3. 进入会话查看历史消息、发送消息和重命名；历史会话可继续。
4. 工具请求展示实际参数，允许一次或拒绝。提交后等待电脑裁决；过期请求不能再次执行。
5. 输入型请求可选择选项、补充文本并提交。排队中且尚未调用的消息可取消；执行中的任务可停止。
6. 返回列表或切换会话时保留各自草稿。网络异常时保留待发送记录，重试沿用同一请求 ID。

客户端在前台轮询同步；后台推送、离线运行代理、电脑屏幕远程控制不在本版本范围内。电脑必须保持在线并运行 Host。

公共 relay 在本次测试中出现过间歇 TLS 握手超时。App 会保留连接和待发记录，网络恢复后可刷新，并通过消息上的重试按钮继续；对连接稳定性有要求时使用自有 HTTPS Hub 地址。

若本机 `/health` 正常而公共地址持续握手超时，可在测试期间重新启动 Host 的 relay；本次重启隔离测试隧道后 HTTPS 恢复。手机保留原连接和待发 ID，无需反复创建新会话。

## CodeBuddy 对话来源

接入的是 CodeBuddy CLI 的真实 ACP 接口 `codebuddy --acp --agent cli --permission-mode default`。新会话和由本 Host 管理的历史会话可以远程控制，恢复使用 ACP 宣告支持的 `session/load`。未实现枚举或接管 CodeBuddy IDE 内所有既有项目分组及对话；IDE 侧未公开的状态不能凭 CLI 接口自动同步。

CodeBuddy 使用标准权限模式，App 不提供跳过审批的入口。实现保留了 HAPI 的 Codex 路径；两个 provider 的会话、草稿与审批按会话隔离。

## 历史会话

App 默认只能看到由本 Host 启动或接管的会话，电脑上原有的历史需要先导入。Host 提供两条扫描链路，均由电脑本机读取后注册成 HAPI 会话，导入后即可在手机上浏览并继续对话：

- **Codex**：扫描 `~/.codex/sessions/**/*.jsonl`。摘要只用文件首尾窗口，因为单机历史可达数 GB，整文件读取会让列表接口超时。
- **CodeBuddy**：扫描 `~/.codebuddy/projects/*/*.jsonl`。临时工作目录（`/private/var/folders`、`/tmp` 等）下的会话属于一次性运行，扫描阶段直接排除。

导入后的会话 `lifecycleState` 为 `imported`，并带有原生会话 id（`codexSessionId` / `codebuddySessionId`）。点开时 Runner 用该 id 走 `codex resume` 或 ACP `session/load` 恢复，历史对话随恢复过程载入。

```sh
curl -H "Authorization: Bearer <JWT>" http://<电脑IP>:3106/api/codex/sessions
curl -H "Authorization: Bearer <JWT>" http://<电脑IP>:3106/api/codebuddy/sessions
curl -X POST -H "Authorization: Bearer <JWT>" -H 'Content-Type: application/json' \
  -d '{"sessionIds":["<原生会话 id>"]}' http://<电脑IP>:3106/api/codebuddy/import-sessions
```

两个前提容易漏：

1. **`codex` 必须在 PATH 中**。HAPI 用它启动与恢复会话；若 Codex 只随桌面客户端安装，需要自行建立软链。
2. **Runner 的 workspace 白名单要覆盖历史项目所在目录**。历史按项目分散在用户主目录下，只开放单一目录会让列表被过滤为空。默认已追加主目录，可用 `AGENTLINK_WORKSPACE_ROOTS` 覆盖。

## 消息渲染

对话按消息类型选用组件，分类与电脑端 Web UI 对齐，同一份历史在两端呈现一致：

| 消息类型 | 手机呈现 | 对应 Web 组件 |
| --- | --- | --- |
| 用户文本 | 右对齐气泡 | `UserMessage.tsx` |
| 助手文本 | Markdown（标题/列表/引用/表格），代码块带语言标签、复制与长文折叠 | `markdown-text.tsx`、`CodeBlock.tsx` |
| 思考过程 | ChatGPT 风格：默认只占一行灰色小字（如「思考了 12 秒」），点击才展开 | `reasoning.tsx` |
| 工具调用 | 卡片：图标、工具名、参数摘要、状态图标，展开显示输入与输出（带行号） | `ToolCard.tsx` |
| 工具结果 | 按 `callId` 并入相邻的调用卡片 | `reducerTimeline.ts` |
| 用量/错误/压缩/目标 | 居中状态行，文案与 Web 完全一致（如 `◷ Context 12.0k / 200.0k (6%) · out 2k · cached 3k`） | `SystemMessage.tsx`、`presentation.ts` |
| 协议内部事件 | 不展示 | — |

思考耗时由「思考片段起点」到「后继消息」的时间差推算（`buildChatEntries`），超出 1 秒～10 分钟视为不可靠而不显示；连续的思考片段会合并成一个思考块。

解析入口是 `lib/domain.dart` 的 `ChatMessage._decode`，它产出 `MessageView` 与各形态载荷；`buildChatEntries` 负责把结果并入调用卡片。渲染组件在 `lib/message_views.dart`。

状态行文案由 `formatTokenCount` / `formatTokenCountLabel` 生成，规则逐条对应 Web 端 `presentation.ts`，改动其中一侧时另一侧需要同步。

未对齐的部分：工具专属视图（Diff、CodexReview、子代理卡片、生成图片）与 Mermaid/KaTeX，手机端仍按通用形态展示。

## 列表页信息架构

工作台是「项目 → 会话 → 对话」的两段式下钻，每一层只承担一个判断：

| 层级 | 显示 | 不显示 |
| --- | --- | --- |
| 工作台 | 项目名、`N 个会话 · M 项待确认`、状态点 | 完整路径、会话标题、卡片内按钮 |
| 项目内 | 会话标题、状态点、相对时间 | 头像、图标、状态描述句 |
| 对话 | 消息流、待审批表单 | — |

早期版本把 6 个元素塞进一张项目卡（头像圈、项目名、完整路径、统计行、两个会话按钮、箭头），
标题在两处重复出现（页内大标题 + AppBar），同一位置的头像圈还承担了两种语义
（项目用首字母、会话用图标）。现在统一为：

- **标题即位置**：AppBar 显示「工作台 / 项目名 / 会话名」，页内不再重复大标题。
- **状态用点**：`StatusDot` 以 9px 圆点表达 待处理(琥珀) / 执行中(青绿) / 在线(品牌蓝) / 已结束(浅灰)。
- **时间替描述**：`formatRelativeTime` 产出「刚刚 / 12 分钟前 / 昨天 / 9 月 10 日」，取代
  「在线 · 可以继续输入」这类长句。
- **尺寸统一**：间距走 `AgentLinkSpace`（4 的倍数），列表卡片统一由 `ListCard` 渲染。

共享组件都在 `agentlink_theme.dart`，供各页复用，避免同一种样式在不同页面写出不同参数：

| 组件 | 用途 |
| --- | --- |
| `ListCard` | 列表行外壳（白底、圆角 14、统一内边距）；`onTap` 传 null 即为禁用态 |
| `RowChevron` | 行尾箭头 |
| `StatusDot` | 状态点（含颜色语义） |
| `SectionLabel` | 分组标题 |
| `EmptyState` | 列表空态 |

弹窗材质也统一到卡片：`dialogTheme` 设为白底 + 细边框，不再用 Material 默认的灰底。

## 配对、设备与新建会话

这三页与列表页共用同一套组件与间距：

- **配对页**：去掉了营销式大标题与占掉半屏的深色宣传块，也去掉了两个不可点击的
  Agent 装饰标签；改为「图标 + 标题 + 一句说明」的页头，扫码作为主路径置顶，
  手动填写放在分隔线之下。
- **设备管理页**：去掉与 AppBar 重复的页内标题；`Card + ListTile` 换成 `ListCard`；
  三类不同的 leading 图标统一为 `StatusDot`（已配对且在附近 / 已配对但未发现 / 新发现）；
  无发现时的纯文本换成 `EmptyState`。
- **新建会话弹窗**：分组标签与输入框自带的 label 在视觉上区分开；代理不可用、错误、
  启动中等状态改用次级文字色而非无样式正文；路径字段补了 `在电脑上运行 pwd 即可看到`
  的提示。

## 会话交互：离线会话自动恢复

历史会话导入后在电脑上没有对应进程（`active=false`）。早期版本要求用户先点一次头部
的「继续会话」才能输入，而输入框此时是禁用状态 —— 用户进入会话的第一反应是「点一下
输入框」，得到的却是没反应。现在改为：

- **输入框始终可用**。离线会话的提示语是「输入消息，发送后自动启动会话…」。
- **发送时自动恢复**：`AppModel.sendOrResume` 先恢复会话，成功后再投递消息；
  恢复失败则不发送，避免消息落到已归档的会话上。
- **启动期间即时反馈**：按钮转圈 + 头部状态显示「正在启动…」，不必等下一次轮询。
- **启动期间缩短轮询**：由 2 秒改为 600 毫秒，让「已结束 → 在线」尽快显示；恢复
  结束后自动回到 2 秒。

恢复可能让电脑端新建一个活跃会话（id 变化）。模型会把 `selectedSession` 切到新 id，
`Chat` 用 `ValueKey(selectedSession)` 作为 key，因此会话切换时整个输入区会重建，
草稿由模型迁移到新 id 上承载。

头部的「继续会话」按钮保留，用于「只想启动、暂不发送消息」的场景。

对话页头部的状态依次取：`正在启动…`（本地恢复中）→ `已归档`（离线）→ `运行中`
（执行中）→ `在线`。

## 消息滚动与审批呈现

**消息始终跟随最新**：`_ChatState` 监听模型变化，消息条数增加时自动滚到底部。只在
用户本来就贴着底部时跟随（距底 120px 以内），他主动往上翻看历史时不会被打断。

**审批改为弹出确认层**。此前待确认请求固定在消息列表上方，一条长命令会把对话区按住
好几屏 —— 而用户往往正想看下面的新回复。现在：

- 出现新请求时自动弹出底部确认层（同一请求只自动弹一次）；
- 收起后，输入区上方留一个「N 项操作等待确认 · 点击处理」提示条可重新打开；
- 确认层里的命令详情**默认收起**，只留「查看命令详情」入口，需要核对时再展开；
- **危险提示不受折叠影响**：命中 `rm -rf` / `sudo` 等破坏性片段时始终显式可见。
  折叠是为了少占屏幕，不是为了让人盲批。

确认层用 `AnimatedBuilder` 订阅模型：提交后电脑端裁决会改变请求状态，内容随即刷新，
而不是停在打开时的快照。

## 模型选择

会话头部提供模型入口（芯片图标），只对 Codex 与 CodeBuddy 会话显示。两者的列表来源不同，
但对外是同一个问题，客户端归一成 `ModelOption`：

| Agent | 列表来源 | 当前值来源 |
| --- | --- | --- |
| Codex | `GET /api/sessions/:id/codex-models`（已有） | 会话摘要 `model` |
| CodeBuddy | `GET /api/sessions/:id/codebuddy-models`（新增） | 会话摘要 `model` |

切换都走 `POST /api/sessions/:id/model`。

列表拉取返回 **null 与空列表含义不同**：null 表示这个会话不支持换模型（界面不显示入口），
空列表才会被当成「有入口但没有可选模型」。混用会让用户点开一个空面板。

### CodeBuddy 侧的关键发现

能力表原先把 CodeBuddy 标为不支持换模型（`shared/src/flavors.ts` 的 `codebuddy: new Set()`），
实测下来这个判断不成立。它的 ACP 服务端在 `config_option_update` 里下发了 **4 组配置**：

- `mode` —— 8 档权限模式
- **`model` —— 15+ 个模型，每个带展示名与计费倍率**（如 `Hy4 preview` / `x0.29 credits`）
- `thought_level` —— 7 档思考等级
- `sandbox` —— 沙箱开关

且 `session/set_config_option` 配 `configId='model'` 可以**运行中切换**（实机验证通过）。

之所以一直没被发现，是因为 `AcpSdkBackend` **只从 `session/new` 的响应捕获 configOptions，
不处理 `config_option_update` 通知** —— 这也正是权限档位当初要靠硬编码 `configId` 绕过的原因。
本轮把通知接进 `handleSessionUpdate` 后，模型列表自然就能取到。

改动清单：

| 文件 | 改动 |
| --- | --- |
| `cli/src/agent/backends/acp/constants.ts` | 补 `configOptionUpdate` 通知类型 |
| `cli/src/agent/backends/acp/AcpSdkBackend.ts` | 从通知捕获 configOptions；选项保留 `description` |
| `cli/src/codebuddy/codeBuddyRemoteLauncher.ts` | `modelMode` 由 `ignore` 改为 `nullable`，新增 `applyModel`，注册 `listCodebuddyModels` |
| `cli/src/codebuddy/session.ts` | 新增 `setModel`（keepAlive 随之上报） |
| `shared/src/flavors.ts` | CodeBuddy 补 `ModelChange` 能力 |
| `shared/src/rpcMethods.ts` / `hub/src/sync/rpcGateway.ts` / `hub/src/sync/syncEngine.ts` / `hub/src/web/routes/sessions.ts` | 打通列举模型的 RPC 与路由 |

## 用量

AppBar 的图表图标进入用量页，数据来自电脑端 `GET /api/usage/summary`：

| 区块 | 内容 |
| --- | --- |
| 总计 | 总 token、输入/输出/缓存读写、请求数、会话数 |
| 按 Agent | Codex 与 CodeBuddy 各自的消耗 |
| 按模型 | 按 token 降序，命中缓存的收益看「未缓存」 |
| 每日 | 柱状，长按显示具体数值 |

范围可切 `7d` / `30d` / `all`；页面打开时拉一次，不参与轮询。

**口径**：电脑端只统计**本 Host 管理**的会话。导入的历史不计入 —— `usageService` 在解析阶段
就排除了 `hapiUsageScope === 'imported-history'` 的事件，所以这里的数字比电脑上跑过的总量小。

**时区**：按天分组依赖 IANA 时区名，而 Dart 只暴露时区缩写与偏移量。客户端用等价的固定偏移
时区 `Etc/GMT±N` 代替（中国等无夏令时的地区完全等价），非整点偏移（如印度 +5:30）退回 UTC。

### 历史用量

用量页分两组展示，因为两种口径**不能相加**：

| 组 | 含义 | 算法 |
| --- | --- | --- |
| **本机消耗** | 由本 Host 管理期间产生的用量 | 累计值按流求差 |
| **历史累计** | 导入的会话各自的总量 | 取每个会话**最后一条**累计快照 |

第二组依赖 `usage_events.scope`（schema v27）。CLI 给重放的历史打了
`hapiUsageScope: 'imported-history'`，而早期实现的做法是**在解析阶段直接丢弃**，
于是导入的历史在用量页上完全不可见。现在改为记录来源、汇总时分流，而不是二选一。

来源判定（`parseUsageEvent` 的 `scope`）：

- 有 `imported-history` 标记 → `imported`
- 或：会话是导入的（`codexSourceSessionId` / `lifecycleState === 'imported'`）
  **且**消息没有显式 `threadId` → `imported`（更早版本留下的数据没有标记，靠会话身份兜底）
- 其余 → `managed`

历史组刻意**不做增量求差**：累计值的起点在 HAPI 之外，差值会少算掉那一段，
只有"取最后一条"才是这个会话在该范围内的总量。

实测效果（83 个导入会话）：本机 0.08M，历史 3871M。首次查询会回填全量历史，
本机数据量下约 2.5 秒。

## 上下文用量与账户额度

### 上下文百分比的口径

状态行里的 `Context 75k / 258k (29%)` 取的是**本轮请求**的输入量（`info.last`）。
此前取的是会话累计值（`info.total`），而累计输入是会话至今所有请求的总和，会远超
窗口 —— 实测出现过 `Context 69.8M / 258.4k (27027%)` 这种荒谬结果。现在三端
（Flutter `domain.dart`、Web `presentation.ts`、Android `ToolPresentation.kt`）
口径一致：Context 用本轮值，`out` / `cached` / `reasoning` 仍用累计值（它们表达
的是这个会话至今的消耗，两种口径各自成立）。早期载荷没有 `last` 时退回累计值。

### 账户额度

Codex 把账户额度搭在 `token_count` 事件上一起下发（另有一条独立的
`account/rateLimits/updated` 通知），字段是套餐、各时间窗已用比例与重置时间：

```json
{ "primary":   { "used_percent": 99, "window_minutes": 10080, "resets_at": 1789819456 },
  "secondary": { "used_percent": 97, "window_minutes": 10080, "resets_at": 1788455712 },
  "plan_type": "pro",
  "credits":   { "has_credits": false, "unlimited": false, "balance": "0" } }
```

`window_minutes` 的常见取值：300（5 小时）、10080（7 天）、43200（30 天）。
`resets_at` 是**秒**，客户端会按量级归一成毫秒。Codex 只在真正受限时填
`primary` / `secondary`，平时是 null —— 所以不能因为字段为空就判定「没有额度」。

数据链路与各环节原先的问题：

1. **CLI**（`cli/src/codex/utils/appServerEventConverter.ts`）原本把
   `account/rateLimits/updated` **直接丢弃**，额度从来没出过电脑。现在归一成
   camelCase 的 `rateLimits` 随 `token_count` 下发（两套键名都接受）。
2. **Hub 导入历史**（`hub/src/web/routes/codexDesktop.ts`）原本要求 `info` 非空，
   而只带额度的 `token_count` 是 `info: null`，会被整条丢掉。现在保留。
3. **App**（`app_model.dart` 的 `_trackRateLimits`）从已经在轮询的消息流里取最新
   快照 —— 不新增接口、不额外轮询。用量页顶部由 `_QuotaCard` 展示；拿不到时说明
   原因，而不是留白。

**CodeBuddy 没有额度来源**：ACP 下发的 4 组 configOptions（mode / model /
thought_level / sandbox）不含额度，其 Web 侧的 `/v2/billing/*` 端点也未在本仓库
实现。所以额度卡片只对 Codex 会话有效，CodeBuddy 会话下会停在「还没有读到额度
信息」的说明上。

### 用量页的缺失状态

`loadUsage` 在未连接时会写入 `error`，页面据此区分两种情况：读不到（显示错误原因
与「重新读取」按钮）与真的没有数据（显示空状态）。此前两者共用一句「这段时间没有
用量」，用户看到只会以为历史丢了 —— 而真实原因往往是请求根本没发出去。

## 权限模式

会话头部提供权限模式入口（盾牌图标），走电脑端的 `POST /api/sessions/:id/permission-mode`：

| Agent | 可选模式 |
| --- | --- |
| Codex | 默认 / 只读 / 安全全自动 / 全自动（4 档） |
| **CodeBuddy** | **默认 / 自动接受编辑 / 计划模式 / 自动 / 不询问 / 跳过权限检查 / 完全访问 / 由父会话管理（8 档）** |
| Claude | 默认 / 自动接受编辑 / 自动 / 计划模式 / 全自动 |
| Cursor | 默认 / 计划模式 / 每次询问 / 自动审查 / 全自动 |

每档都带一句说明（如「只分析，不修改文件也不执行命令」）；会跳过权限检查的档位用琥珀色警示标出。

### CodeBuddy 的权限模式

此前 HAPI 把 CodeBuddy 硬编码成只有 `default`（6 处锁点）。实测其 ACP 服务端会在 `session/new` 的
`config_option_update` 里下发 `configOptions[category=mode]`，共 8 档，且**支持会话运行中实时切换**：

- 电脑端放开白名单（`shared/src/modes.ts`、`cli/src/runner/run.ts`、`cli/src/commands/codebuddy.ts`）；
  `cli/src/codebuddy/codeBuddyRemoteLauncher.ts` 注册 `set-session-config` RPC，转发为 ACP 的
  `session/set_config_option`（`configId` 固定为 `mode`）。
- 之所以直接发 `set_config_option` 而不用 `AcpSdkBackend.setMode`：CodeBuddy 是用 `session/update`
  通知下发档位的，而 backend 只从响应里捕获 configOptions，`setMode` 会找不到 mode 选项。
- 启动路径单独处理：ACP 子进程固定以 `--permission-mode default` 启动，所以恢复一个曾是 `plan`
  的会话时必须显式切一次，不能拿 session 当前值比较（否则会被误判为无需切换）。

验证：切 `plan` / `bypassPermissions` / `acceptEdits` / `default` 全部返回 `200 {"ok":true}`，
Hub 侧正确落库，且 ACP 进程 PID 未变 —— 确认是运行中切换而非重启进程。

权限档位随会话摘要下发（`SessionSummary.permissionMode`），手机端显示的是电脑端上报的真实值，
不再是本地猜测。

## 审批卡片

待确认的操作不再直接渲染 JSON 参数，而是按工具类型提取要点：

| 工具类型 | 主信息 | 附带 |
| --- | --- | --- |
| 命令类 | 命令行本身 | 工作目录 + 危险提示 |
| 写入/编辑类 | 文件路径 | 写入行数 |
| 读取/搜索类 | 路径或模式 | — |
| 网络类 | 目标地址 | — |
| 未知工具 | 首个像目标的字段 | 键值对（非裸 JSON） |

命中 `rm -rf` / `sudo` / `git push --force` / `git reset --hard` 等破坏性片段时，
在按钮上方给出显式警示，避免「允许一次」被顺手点掉。

## 构建与复验

```sh
cd flutter
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

源码目录返回仓库根目录后：

```sh
bun run typecheck
bun run test
node scripts/dev/codebuddy-acp-smoke.mjs handshake
AGENTLINK_DART_BIN=/你的/flutter/bin/dart node scripts/dev/agentlink-live-smoke.mjs
```

完整联调脚本使用临时目录和真实代理，验证认证、消息、请求去重、改名、审批的文件结果、停止、CodeBuddy 恢复和 Codex 会话隔离。仅在电脑上运行，不会连接用户手机。失败时保留隔离目录供诊断，成功时清理。

## 交给用户的真机验收

安装 APK 后验证：默认 HTTPS 或受信任 LAN 配对 → Codex / CodeBuddy 切换 → 两个项目中的会话和标题 → 发送、返回、恢复历史 → 实际工具允许/拒绝 → 切换网络后刷新与重试 → 杀进程重开后恢复连接。最后确认字体、中文输入法、键盘遮挡和 Android 后台恢复是否符合自己的手机行为。

本地构建、模拟器和电脑代理联调的结果见 `agentlink-validation.md`。真机测试只由用户完成，不能用模拟器结果替代。

## 来源与许可

基于 [tiann/hapi](https://github.com/tiann/hapi)，遵循仓库 AGPL-3.0 许可及已有 NOTICE。CodeBuddy 接入采用其 ACP 协议，没有复制 Octop 源代码。对外分发修改版时应一并保留许可与对应源码；本次没有提交、推送或发布到应用商店。
