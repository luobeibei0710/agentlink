#!/usr/bin/env node
/**
 * 让手机经公网 HTTPS 连接本机 Hub。
 *
 * 做三件事：
 * 1. 探测本机已在运行的 Hub（默认 3106，回环与物理网卡都试）；
 * 2. 用 cloudflared 快速隧道把它暴露成一个公网 HTTPS 地址；
 * 3. 生成配对二维码、配对链接与浏览器直连地址。
 *
 * 为什么必须要有隧道：手机端 connection_policy.dart 只接受 HTTPS
 * （HTTP 仅限 10.x / 172.16-31.x / 192.168.x 私有段的局域网地址），
 * 而 Hub 自身用 Bun.serve 监听、不提供 TLS。
 *
 * 用完 Ctrl+C 退出即可，隧道会一并关闭；Hub 不受影响。
 */
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { createRequire } from 'node:module';
import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { homedir, networkInterfaces } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const port = Number(process.env.AGENTLINK_PORT || '3106');
const hapiHome = process.env.AGENTLINK_HOME || join(homedir(), '.agentlink');

/** 依次尝试回环与各物理网卡地址，返回第一个 /health 可达的基地址。 */
async function detectHub() {
    const candidates = ['127.0.0.1'];
    for (const addresses of Object.values(networkInterfaces())) {
        for (const address of addresses ?? []) {
            if (address.family === 'IPv4' && !address.internal) candidates.push(address.address);
        }
    }
    for (const host of candidates) {
        const base = `http://${host}:${port}`;
        try {
            const response = await fetch(`${base}/health`, { signal: AbortSignal.timeout(1500) });
            if (response.ok) return base;
        } catch {
            // 继续试下一个地址。
        }
    }
    return null;
}

/** 启动 cloudflared 快速隧道，从输出里解析分配到的公网地址。 */
function startTunnel(target) {
    return new Promise((resolveTunnel, reject) => {
        const child = spawn('cloudflared', ['tunnel', '--url', target, '--no-autoupdate'], {
            stdio: ['ignore', 'pipe', 'pipe'],
        });
        // 隧道日志另行留存：本机 DNS 未同步时表现为「连不上」，靠日志才能区分是
        // 隧道没起来还是解析没生效。
        const logFile = join(hapiHome, 'cloudflared.log');
        mkdir(hapiHome, { recursive: true, mode: 0o700 }).catch(() => {});
        const logStream = createWriteStream(logFile, { mode: 0o600 });
        let settled = false;
        const finish = (error, value) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            if (error) reject(error);
            else resolveTunnel(value);
        };
        const onData = chunk => {
            logStream.write(chunk);
            const match = chunk.toString().match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
            if (match) finish(null, { child, url: match[0], logFile });
        };
        child.stdout.on('data', onData);
        child.stderr.on('data', onData);
        child.once('exit', () => logStream.end());
        // cloudflared 未安装时 spawn 会异步报 ENOENT。
        child.once('error', error => finish(
            error.code === 'ENOENT'
                ? new Error('未找到 cloudflared，请先执行：brew install cloudflared')
                : error
        ));
        child.once('exit', code => finish(new Error(`cloudflared 提前退出（code ${code}），日志：${logFile}`)));
        const timer = setTimeout(() => {
            child.kill('SIGTERM');
            finish(new Error(`cloudflared 60 秒内没有分配公网地址，日志：${logFile}`));
        }, 60_000);
    });
}

/**
 * 轮询公网地址直到 /health 通过。
 *
 * Cloudflare 在分配域名后会先把 DNS 解析出来，边缘路由才逐步生效，实测需要
 * 10～60 秒。因此前几次探测间隔短（应对秒级就绪），之后拉长到 4 秒并把总
 * 窗口放到约两分钟，避免刚分配就判失败。
 */
async function waitUntilReachable(publicUrl) {
    for (let attempt = 0; attempt < 30; attempt += 1) {
        try {
            const response = await fetch(`${publicUrl}/health`, { signal: AbortSignal.timeout(6000) });
            if (response.ok) return true;
        } catch {
            // 隧道刚建立时 DNS 与边缘路由可能都还没生效。
        }
        if (attempt === 4) console.log('  公网地址还没生效，继续等待（Cloudflare 边缘注册需要一点时间）…');
        await new Promise(done => setTimeout(done, attempt < 5 ? 1500 : 4000));
    }
    return false;
}

async function readCliApiToken() {
    const settings = JSON.parse(await readFile(join(hapiHome, 'settings.json'), 'utf8'));
    if (typeof settings.cliApiToken !== 'string' || !settings.cliApiToken) {
        throw new Error(`${hapiHome}/settings.json 里没有 cliApiToken，请先启动一次 Host。`);
    }
    return settings.cliApiToken;
}

async function main() {
    const hubBase = await detectHub();
    if (!hubBase) {
        console.error(`没有在 ${port} 端口发现可用的 Hub。`);
        console.error(`请先在另一个终端启动电脑端：`);
        console.error(`  AGENTLINK_NO_RELAY=1 bun scripts/dev/agentlink-host.mjs '/你的项目路径'`);
        console.error(`（用 --no-relay 是因为公网出口交给本脚本的隧道，避免重复占用官方 relay。）`);
        process.exit(1);
    }
    console.log(`Hub: ${hubBase}`);

    const cliApiToken = await readCliApiToken();
    const { child: tunnel, url: publicUrl } = await startTunnel(hubBase);
    console.log(`公网地址: ${publicUrl}`);
    console.log('等待隧道就绪…');

    if (await waitUntilReachable(publicUrl)) {
        console.log('隧道已就绪。\n');
    } else {
        // 探测不到不阻断：最常见的原因是本机 DNS 还没同步这个新建的随机子域
        // （部分公共 DNS 的负缓存要过一阵才失效），而不是隧道本身有问题 ——
        // 实测此时用其它 DNS 或直接指定解析结果访问都是通的。手机走运营商
        // DNS 通常不受影响，所以照常输出配对信息，不白白浪费一次隧道分配。
        console.log('提示：本机暂时解析不到这个新域名，一般是 DNS 未同步（不是隧道故障）。');
        console.log('手机通常可以正常连接；若也连不上，等一两分钟重试。\n');
    }

    const companionUrl = `hapicompanion://bind?hub=${encodeURIComponent(publicUrl)}&code=${encodeURIComponent(cliApiToken)}`;
    const webUrl = `https://app.hapi.run/?hub=${encodeURIComponent(publicUrl)}&token=${encodeURIComponent(cliApiToken)}`;

    const require = createRequire(join(root, 'hub/package.json'));
    const QRCode = require('qrcode');
    const qrOptions = { errorCorrectionLevel: 'L', margin: 1 };
    console.log('手机配对二维码（用系统相机扫，或 App 内「扫码或手动连接」）：');
    console.log(await QRCode.toString(companionUrl, { ...qrOptions, type: 'terminal', small: true }));

    console.log('\n手动配对信息：');
    console.log(`  Hub 地址: ${publicUrl}`);
    console.log(`  配对码:   ${cliApiToken}`);

    console.log('\n浏览器直连（在电脑上打开）：');
    console.log(`  ${webUrl}`);

    // 写一份本地配对页，方便随时回看；配对码等同会话访问权限，权限收紧到 0600。
    await mkdir(hapiHome, { recursive: true, mode: 0o700 });
    const qrDataUrl = await QRCode.toDataURL(companionUrl, { ...qrOptions, scale: 8 });
    const htmlFile = join(hapiHome, 'agentlink-public-pairing.html');
    await writeFile(htmlFile, `<!doctype html><meta charset="utf-8"><title>AgentLink 公网配对</title>
<body style="font-family:system-ui;padding:2rem;max-width:640px;margin:auto">
<h1>AgentLink 公网配对</h1>
<p>用手机扫描下面的二维码，或在 App 内手动填写地址与配对码。</p>
<img src="${qrDataUrl}" alt="配对二维码" style="width:280px;height:280px">
<p><b>Hub 地址</b><br><code>${publicUrl}</code></p>
<p><b>配对码</b><br><code>${cliApiToken}</code></p>
<p style="color:#a15c00">这个二维码等同于电脑会话的访问权限，不要截图外发。隧道关闭后地址即失效。</p>
</body>`, { mode: 0o600 });
    await chmod(htmlFile, 0o600);
    console.log(`\n本地配对页（0600）：${htmlFile}`);
    console.log('\n公网连接已就绪，保持本终端运行。按 Ctrl+C 关闭隧道。');

    const stop = () => {
        tunnel.kill('SIGTERM');
        process.exit(0);
    };
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);
    tunnel.once('exit', code => {
        if (code !== 0 && code !== null) console.error(`隧道已关闭（code ${code}）。`);
        process.exit(code ?? 0);
    });
}

await main();
