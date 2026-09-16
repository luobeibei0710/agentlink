# AgentLink 公网 Host

手机不在电脑所在局域网时，用这一页的方式连接。核心约束是：**手机端只接受 HTTPS**
（只有 10.x / 172.16–31.x / 192.168.x 的私有地址允许用 HTTP），而 Hub 用 `Bun.serve`
监听、自身不提供 TLS。所以公网访问必须由一个能提供受信任证书的入口来承担。

三种入口按需要选一种即可，Hub 侧不用改代码：

| 入口 | 地址形态 | 是否固定 | 前置条件 |
| --- | --- | --- | --- |
| 官方 relay（默认） | `https://xxx.relay.hapi.run` | 否 | 无 |
| Cloudflare 快速隧道 | `https://随机词.trycloudflare.com` | 否 | 装 `cloudflared` |
| Cloudflare 固定域名隧道 | `https://hub.你的域名` | **是** | 域名托管在 Cloudflare |

## 用 Cloudflare 隧道替代官方 relay

电脑上先装一次：

```sh
brew install cloudflared
```

在另一个终端启动电脑端（**注意用 `--no-relay`**，公网出口交给隧道，避免同时占用官方 relay）：

```sh
AGENTLINK_NO_RELAY=1 bun scripts/dev/agentlink-host.mjs '/你的项目完整路径'
```

再启动隧道脚本，它会自动探测已在运行的 Hub、建立隧道、等待就绪，并输出配对二维码：

```sh
node scripts/dev/agentlink-public.mjs
```

脚本做三件事：探测 Hub → 起 `cloudflared` 隧道 → 打印配对二维码、配对码和浏览器直连地址。
按 Ctrl+C 关闭隧道，Hub 不受影响。隧道日志留在 `~/.agentlink/cloudflared.log`，
配对页留在 `~/.agentlink/agentlink-public-pairing.html`（权限 `0600`）。

### 为什么不用 `--lan` 一起跑

`--lan` 会强制关闭 relay 并把 Hub 绑到物理网卡，服务范围仍是局域网。公网访问应该让 Hub
保持只听 `127.0.0.1`，由隧道从本机转发出去；本页脚本对两种绑定方式都做了探测，所以即使
Hub 已经跑在局域网地址上也能直接套隧道。

## 固定域名（长期使用推荐）

快速隧道每次重启都会换一个随机域名，配对码和手机里的地址都要跟着更新。要一个稳定地址，
把域名接入 Cloudflare 后建一条命名隧道：

```sh
cloudflared tunnel login
cloudflared tunnel create agentlink
cloudflared tunnel route dns agentlink hub.你的域名.com
cloudflared tunnel run --url http://127.0.0.1:3106 agentlink
```

之后每次只需最后一条 `run`。域名固定，手机配对一次即可长期使用。

若域名不在 Cloudflare，可改用任意能提供 HTTPS 的反向代理（VPS + Caddy、frp 等），
只要最终对手机暴露的是受信任的 HTTPS 根地址即可。

## 手机配对

两种方式等价：

- **扫码**：用系统相机扫终端二维码，或 App 内「扫码或手动连接」；
- **手动**：在 App 的配对页填写 Hub 的 HTTPS 地址与配对码。

配对码就是 Hub 的 `cliApiToken`（`~/.agentlink/settings.json`），它是**长期有效**的共享密钥，
换取的是 4 小时有效的 JWT。它等同于电脑会话的完整访问权限，不要截图外发。

## 已知问题：新建随机域名的 DNS 同步延迟

Cloudflare 快速隧道每次分配的都是全新子域。实测部分公共 DNS 对新子域的负缓存要过一阵才失效，
表现为**本机 `curl` 或浏览器打不开该地址**（`NXDOMAIN`），但隧道其实完全正常。

判断方法：用其它 DNS 对照，若只有本地 DNS 解析失败就属于这一类。

```sh
dig @223.5.5.5 +short 你的域名.trycloudflare.com   # 有结果
dig @114.114.114.114 +short 你的域名.trycloudflare.com   # 可能为空
curl -s --resolve 你的域名.trycloudflare.com:443:<上一步的IP> https://你的域名.trycloudflare.com/health
```

此时**手机通常仍可连接**（运营商 DNS 同步更快）。若手机也连不上，等一两分钟重试。
固定域名不存在这个问题，这也是长期使用建议用命名隧道的原因。

## 安全说明

- Hub 保持只听 `127.0.0.1` 即可，隧道从本机转发，不必暴露到局域网。
- 隧道地址本身不设访问控制，**唯一门禁是配对码**，务必不要公开地址与二维码。
- 手机端对公网 Hub **不做证书指纹固定**（只有局域网设备配对才有指纹固定与 8 位数字核验），
  安全性依赖 HTTPS 证书链本身。重视这一点的场景应使用自己的域名与证书。
- 手机在前台每 2 秒轮询一次，公网下会持续产生小请求；按流量计费的出口需要留意。
