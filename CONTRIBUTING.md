# 贡献指南

感谢你有兴趣参与 AgentLink。本文件说明开发环境、提交前必须通过的检查，以及几个容易踩的约定。

## 先分清边界

AgentLink 是 [tiann/hapi](https://github.com/tiann/hapi) 的衍生项目 —— README 的「与原版 hapi 的关系」一节列了哪些来自上游、哪些是本项目新增。动手前先确认要改的是哪一侧：

- **上游已有的模块**（Hub 的会话同步与权限路由、Runner、跨端协议 `shared/`、Web 客户端）：改动尽量贴合上游风格，避免制造无谓的合并冲突。
- **本项目新增**（`flutter/`、`cli/src/codebuddy/`、公网 Host、用量与额度）：可以按本项目自己的判断演进。

## 开发环境

| | 要求 |
| --- | --- |
| 系统 | macOS（Runner 目前只实现了 macOS） |
| 运行时 | [Bun](https://bun.sh) 1.4+ |
| 客户端 | Flutter（Dart SDK 3.11.5+） |
| 已登录的 CLI | `codex`、`codebuddy` —— 联调时必须能真的驱动会话 |

```bash
bun install
cd flutter && flutter pub get
```

## 提交前必跑

改动落在哪个包就跑对应的那组，**全绿再提交**。

```bash
# 类型检查（四个包并行）
bun run typecheck

# 电脑端
bun run test:hub
bun run test:web
bun run test:shared
cd cli && ./node_modules/.bin/vitest run     # cli 不走 bun test，用 vitest

# 客户端
cd flutter
flutter analyze
flutter test
```

联调真实会话（会启动 Hub 并驱动本机的 `codex` / `codebuddy`）：

```bash
HAPI_BUN_BIN="$HOME/.local/bin/bun" node scripts/dev/agentlink-host.mjs --lan
```

## 几个容易踩的约定

**数据库迁移必须幂等。** Hub 的 schema 由 `hub/src/store/index.ts` 的 `SCHEMA_VERSION` 与 `PRAGMA user_version` 顺序驱动。`createSchema` 建出的新库已含最新列，任何让旧步骤重跑的路径都会撞上已存在的列 —— `v26→v27` 就曾漏了列存在性检查，直接 `ALTER TABLE` 抛 `duplicate column name`，让整个 Store 起不来。改列之前先 `PRAGMA table_info` 查一次；升级 `SCHEMA_VERSION` 时记得同步 `hub/src/store/migration-v*.test.ts` 里的断言。

**Web 的 fixture 有漂移门禁。** `shared/fixtures/` 下的目录与用例是生成的，改了 `shared/src/modes.ts` 这类来源模块后必须重新生成，否则 `web` 的测试会失败：

```bash
bun run gen:fixtures
```

**渲染口径要三端一致。** 同一条消息在三处都有实现：Flutter（`flutter/lib/domain.dart`）、Web（`web/src/chat/presentation.ts`）、Android（`android/core/protocol/.../ToolPresentation.kt`）。改了一端的行为，另外两端要跟着改，否则同一份历史在不同端看起来不一样。上下文用量就出过这个问题 —— 三端都拿会话累计值去比上下文窗口，显示成 `27027%`。

**渲染快照只在确认差异符合预期后更新。**

```bash
cd flutter && flutter test --update-goldens
```

注意快照是**按平台生成**的：同一份代码在 macOS 与 Linux 上光栅化结果不同（实测差异 1.9%–4.3%）。快照用 macOS 生成，所以 CI 用 `flutter test --exclude-tags golden` 跳过它们（见 `flutter/dart_test.yaml`）—— 换了平台开发的话，别把快照更新进去。

**不要提交构建产物与密钥。** `artifacts/`、`flutter/build/`、`.dart_tool/` 已在 `.gitignore` 中；发布用的 APK 走 GitHub Release，不入库。`~/.agentlink/settings.json` 里存的是长期有效的配对码，别贴进 issue 或提交。

## 提交信息

沿用 [Conventional Commits](https://www.conventionalcommits.org/)，标题用中文简述结论，正文说明**为什么**改（而不是复述改了什么）：

```
feat(hub): 用量汇总、模型与会话路由，并修正 v27 迁移幂等性
fix(web): 上下文用量改用本轮请求的输入量
test(shared): 对齐 CodeBuddy 权限档位的过期断言与 fixture
docs: 充实 README —— 系统要求、会话交互与模型切换、常见问题、版本
```

按领域拆分提交，不要把无关模块塞进同一个 commit。

## 发布与签名

发布由 tag 触发（`.github/workflows/android-release.yml`）：推一个 `v1.12.2` 这样的 tag 就会构建 APK 并挂到同名 Release。**tag 必须与 `flutter/pubspec.yaml` 的版本一致**，否则 workflow 直接失败。

发布包用正式密钥签名，密钥与口令都不入库：

- **CI**：从仓库 secrets 还原 —— `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。缺任何一个都会让 workflow 失败（**不会**悄悄退回 debug 签名）。
- **本机**：把密钥放在仓库外（例如 `~/.agentlink/android/agentlink-release.jks`），再写 `flutter/android/key.properties`（已被 `.gitignore` 忽略）：

```properties
storeFile=/绝对路径/agentlink-release.jks
storePassword=…
keyAlias=agentlink
keyPassword=…
```

没有 `key.properties` 时本地构建会回落到 **debug 签名** —— 能装能跑，但**无法覆盖安装已发布版本**（Android 报「应用未安装」）。仅供本地验证，别拿去发布。

> 签名密钥一旦丢失，就无法再给已发布版本推送更新（Android 要求同一应用的更新必须同签名）。请把 keystore 与口令备份到安全的地方。

## 提交 PR

1. 从 `main` 切分支，命名如 `fix/hub-migration-idempotent`；
2. 确保上面的检查全绿，描述里写清**问题、做法、验证方式**；
3. 界面改动请附前后对比截图 —— 用演示数据，别暴露真实项目名与路径；
4. 涉及协议或 schema 变更请在描述里显式说明，便于 review 兼容性。

## 许可

本项目遵循 [AGPL-3.0](LICENSE)。提交贡献即表示同意以同一许可分发。
