# AgentLink 1.2.0 局域网与扫码验收

验证日期：2026-09-13 至 2026-09-14。工作树：`feature/flutter-codebuddy-companion`。

## 交付范围

- Flutter Android App 内相机扫码；扫码后先显示准确 Hub 地址，再配对。
- HTTP 仅接受 RFC1918 IPv4 字面地址；默认 HTTPS，拒绝公网 HTTP、歧义/重复参数和自动认证重定向。
- 已保存的 HTTP 凭据在冷启动时不自动发送；用户确认当前局域网目标后恢复。
- PC Host `--lan` 自动选择物理网卡，支持 `--lan-ip`；只绑定所选地址，不绑定所有网卡。
- PC 在 Hub 和 Runner 就绪后生成终端二维码与 `~/.agentlink/agentlink-lan-pairing.html`；本地配对文件权限为 0600，二维码包含配对凭证，不纳入仓库。
- macOS 双击入口：根目录 `启动局域网连接.command`。详细使用步骤见 [lan-host.md](lan-host.md)。

## 已执行

- `flutter test --reporter expanded`：53 项通过，包含旧扫码页退出动画期间的迟到回调不能弹出新页面的回归测试。
- `flutter analyze`：无问题。
- `node --test scripts/dev/agentlink-lan.test.mjs`：5 项通过。
- Host 和 LAN helper 的 `node --check`、启动入口 `zsh -n` 通过。
- 真实本机 Wi-Fi 地址 `192.168.1.216:3106`：认证返回 200，一个 Runner 在线，Codex 与 CodeBuddy 均报告 available。
- `lsof` 确认 Hub 仅监听 `192.168.1.216:3106`。重复启动命中端口预检，不停止已有服务。
- Android API 36 模拟器：安装 release APK、相机授权、原生 ML Kit 解码配对二维码、确认目标、通过 LAN IP 认证进入工作台、冷启动显示重新确认入口、确认后恢复。
- 原生快速退出/重入曾发现相机重复启动与扫码结果晚到问题，已加入跨路由相机所有者协调、退出即时停止以及非当前页面结果丢弃。
- 最终 APK 已重新安装，快速返回后再次扫码成功显示目标确认，确认后进入真实 LAN Hub 的双 Agent 工作台；APK 签名校验通过。
- 相机输入使用与电脑二维码相同的实际配对内容生成的测试画面，送入模拟器原生相机；不是直接调用扫码回调，也不是物理手机对电脑屏幕拍摄。

## 证据

最终 APK：`artifacts/agentlink/AgentLink-1.2.0-android.apk`，版本 `1.2.0+3`。

SHA-256：`73ed716cdc940a596ac9c66d1d8dd7b842b4544af3e9d63abc2c8b4173e229c0`。

- `artifacts/agentlink/lan-qr-confirm.png`：原生扫码后显示实际 LAN 地址。
- `artifacts/agentlink/lan-connected.png`：真实 Hub 配对成功。
- `artifacts/agentlink/lan-restore-confirm-required.png`：冷启动不会自动向已保存的 HTTP 地址发送凭据。

## 设备验收边界

真机扫码距离/对焦、用户路由器的 AP 隔离、电脑防火墙和手机 VPN 仍需在用户手机上验收。无法仅凭模拟器保证任意局域网策略都允许访问。安装包是 release 构建、debug 签名的测试包，不是商店发布包。

本轮没有改成后台推送，也没有承诺读取 CodeBuddy IDE 的全部历史会话；可控制的会话仍由 HAPI Runner 管理。
