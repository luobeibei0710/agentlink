# AgentLink Android 页面设计

Figma：[AgentLink · Flutter Android](https://www.figma.com/design/D8u9JqxEJfewO1TdOzmxys/AgentLink-Flutter-Android)

本稿为现有 Flutter 功能的视觉与信息架构提案，采用浅灰背景、靛蓝操作色、青绿执行状态、琥珀色审批状态。画板 393 × 852，水平留白 24，主按钮高 52，卡片圆角 16；中文字体优先 PingFang SC。设计脚本仅创建原生可编辑图层，不访问网络。

## 页面

1. 安全连接：Hub 地址、凭据、完整配对链接。
2. 项目工作台：Codex / CodeBuddy 选择、优先处理授权、项目分组。
3. 项目任务：进行中、历史任务、可恢复会话。
4. 新建任务：Agent、在线电脑、项目路径、任务描述。
5. 对话与执行：用户输入、工具结果、运行状态、停止与继续输入。
6. 有效审批：完整命令与目录、允许一次、拒绝；权威确认前不宣称成功。
7. 回答 Agent：单选与补充文字；多选需沿用后端题型约束。
8. 断线与重试：Hub 状态、消息保留、同一请求重试。

主流程连线用于设计演示，并不执行真实任务或授权。未连线的控件为静态设计，不代表完整可用原型。待处理聚合与底部导航已在 Flutter 1.1.0 落地；见 [实施验收](../../docs/agentlink-ui-validation.md)。运行版采用响应式布局，审批和问题表单嵌入会话，保留完整参数和真实授权状态。

## 参考与取舍

| 来源 | 借鉴 | 本稿保留的边界 |
| --- | --- | --- |
| [Happy](https://github.com/slopus/happy) | 电脑、项目、会话分组，状态、最近活动和审批卡 | 不照搬账户体系或全部绕过授权 |
| [omg.dev](https://github.com/BennyKok/omg.dev) | 等待用户处理优先于运行中任务 | 不引入可拖拽看板、云机器或合并操作 |
| [Pocket Codex](https://github.com/acking-you/pocket-codex) | 长历史恢复与明确重试，审查记录与实时审批分离 | 不把其 Codex 专用协议当作多 Agent 合约 |
| [RikkaHub](https://github.com/rikkahub/rikkahub) | Android 聊天排版与模型选择层级 | 仅借鉴交互思想，不复制 AGPL 代码或产品资产 |
| [Kojo](https://github.com/loppo-llc/kojo) | 会话重连及任务状态提示 | 不引入终端、文件 diff 等当前未实现能力 |

“码伴”未确认可信开源仓库。仅找到 [TRAE 同名创意帖](https://forum.trae.cn/t/topic/149965)，不能认定为用户记忆中的项目。

## 实施验收注意点

- Agent 切换只改变任务筛选或新任务类型，不能把一个现有会话转换成另一种 Agent。
- 项目分组来自 Host 管理会话的目录，不承诺接管 CodeBuddy IDE 所有既有分组。
- 审批按钮提交时禁用，必须经 Host 确认；过期、已处理和非当前主机请求不得授权。
- 未确认的发送沿用稳定 requestId/localId；取消消息与停止执行应分开呈现。
- 对话需保持阅读位置，提供更早消息加载；草稿按会话隔离。
- 新增底部待处理页在实施时应聚合真实权限和问题状态，不能用静态计数。
- 固定画板仅定义标准尺寸；Flutter 落地仍需键盘、200% 字体、窄屏和无障碍检查。

## 本次验证

- 已在 Figma 桌面端运行脚本，实际创建 8 个 393 × 852 原生画板，中文文本和图层可编辑。
- 已检查整体画板，并放大检查审批、断线恢复的文字、按钮与底部安全区。
- 已在 Figma Present 模式实际点击“工作台 → 待审批 → 允许一次 → 对话”演示路径，页面跳转正常。此过程只是原型导航，没有执行真实授权。
- `node --check design/agentlink/code.js` 通过。
- Figma 连接器需要重新认证；本次使用已登录的桌面端完成创建，不依赖连接器恢复。

## 本地生成器

`manifest.json` 与 `code.js` 是本次自行编写的本地 Figma 插件。通过 Development → Import plugin from manifest 导入后运行，创建一个新的设计页；重复运行会新建页面而不覆盖已有内容。
