## 问题

<!-- 这个改动解决什么？尽量讲清楚「为什么」，而不只是「改了什么」。 -->

## 做法

<!-- 关键取舍是什么？
     涉及协议或 schema 变更请显式说明兼容性影响 —— schema 迁移必须幂等，见 CONTRIBUTING.md。 -->

## 验证

<!-- 跑了哪些检查？界面改动请附前后对比截图，用演示数据，别暴露真实项目名与路径。 -->

- [ ] `bun run typecheck`
- [ ] 受影响的包测试（`test:hub` / `test:web` / `test:shared`，或 `cd cli && ./node_modules/.bin/vitest run`）
- [ ] `cd flutter && flutter analyze && flutter test`
- [ ] 改了 `shared/` 下的来源模块（如 `modes.ts`）时，已跑 `bun run gen:fixtures`
- [ ] 改了消息渲染时，Flutter / Web / Android 三端口径一致

## 备注

<!-- 已知限制、后续计划，或需要 reviewer 特别关注的地方。 -->
