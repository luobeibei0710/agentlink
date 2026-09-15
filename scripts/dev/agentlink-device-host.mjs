import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { createServer as createHttpsServer } from 'node:https';
import { createSocket } from 'node:dgram';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, readFile, rename, writeFile, chmod, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { isIP } from 'node:net';

const execFileAsync = promisify(execFile);
const protocol = 'agentlink-discovery-v1';
const requestTtlMs = 120_000;
const maxBodyBytes = 1_048_576;
const maxResponseBytes = 10 * 1_048_576;
const noncePattern = /^[A-Za-z0-9_-]{43}$/;
const deviceName = value => typeof value === 'string' && value.length > 0 && value.length <= 80;
const encoded = bytes => bytes.toString('base64url');
const sha256 = value => createHash('sha256').update(value).digest('hex');
const tokenHash = token => sha256(`agentlink-device-token-v1\n${token}`);
const equal = (left, right) => {
    const a = Buffer.from(left || ''); const b = Buffer.from(right || '');
    return a.length === b.length && timingSafeEqual(a, b);
};
const json = (response, status, value) => {
    const data = JSON.stringify(value);
    response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(data), 'Cache-Control': 'no-store' });
    response.end(data);
};
const fail = (response, status, message) => json(response, status, { error: message });
async function body(request) {
    const chunks = []; let length = 0;
    const deadline = setTimeout(() => request.destroy(), 15_000);
    try {
        for await (const chunk of request) {
            length += chunk.length;
            if (length > maxBodyBytes) throw Object.assign(new Error('Request body too large'), { status: 413 });
            chunks.push(chunk);
        }
        if (!length) return {};
        try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw Object.assign(new Error('Invalid JSON'), { status: 400 }); }
    } finally { clearTimeout(deadline); request.setTimeout(0); }
}
function validNonce(value) { return typeof value === 'string' && noncePattern.test(value); }
function sameSubnet(address, selected, netmask) {
    if (isIP(address) !== 4 || isIP(selected) !== 4 || isIP(netmask) !== 4) return false;
    const parts = value => value.split('.').map(Number);
    const [a, b, mask] = [parts(address), parts(selected), parts(netmask)];
    return a.every((part, index) => (part & mask[index]) === (b[index] & mask[index]));
}
function privateAddress(address) {
    if (isIP(address) !== 4) return false;
    const [first, second] = address.split('.').map(Number);
    return first === 10 || (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168);
}
function requestSas(fingerprint, serverNonce, clientNonce, requestId) {
    const digest = sha256(`agentlink-pair-v1\n${fingerprint}\n${serverNonce}\n${clientNonce}\n${requestId}`);
    return String(parseInt(digest.slice(0, 8), 16) % 100_000_000).padStart(8, '0');
}
function commitment(fingerprint, serverNonce, requestId) { return sha256(`agentlink-commit-v1\n${fingerprint}\n${serverNonce}\n${requestId}`); }
async function atomicJson(file, value) {
    const temporary = `${file}.${process.pid}.${encoded(randomBytes(6))}.tmp`;
    await writeFile(temporary, JSON.stringify(value), { mode: 0o600 });
    await chmod(temporary, 0o600); await rename(temporary, file); await chmod(file, 0o600);
}
async function loadJson(file, fallback) {
    if (!existsSync(file)) return fallback;
    try {
        const stat = await import('node:fs/promises').then(fs => fs.stat(file));
        if ((stat.mode & 0o077) !== 0) throw new Error('unsafe permissions');
        const parsed = JSON.parse(await readFile(file, 'utf8'));
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid record');
        return parsed;
    } catch (error) { throw new Error(`AgentLink device state failed integrity checks: ${error.message}`); }
}
async function ensureCertificate(directory, bindAddress, commonName) {
    const key = join(directory, 'device-link.key.pem'); const cert = join(directory, 'device-link.cert.pem');
    if (existsSync(key) !== existsSync(cert)) throw new Error('AgentLink certificate is incomplete; refusing to replace it');
    if (!existsSync(key)) {
        const suffix = `${process.pid}.${encoded(randomBytes(6))}`; const keyTemp = `${key}.${suffix}`; const certTemp = `${cert}.${suffix}`;
        try {
            const subject = commonName.replace(/[^A-Za-z0-9 ._-]/g, '').slice(0, 64) || 'AgentLink Host';
            await execFileAsync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyTemp, '-out', certTemp, '-days', '3650', '-subj', `/CN=${subject}`, '-addext', `subjectAltName=IP:${bindAddress}`]);
            await chmod(keyTemp, 0o600); await chmod(certTemp, 0o600); await rename(keyTemp, key); await rename(certTemp, cert);
        } catch (error) { throw new Error(`Could not create AgentLink certificate: ${error.message}`); }
    }
    if (((await stat(key)).mode & 0o077) !== 0 || ((await stat(cert)).mode & 0o077) !== 0) throw new Error('AgentLink certificate permissions are unsafe');
    const certificate = await readFile(cert); const privateKey = await readFile(key);
    const fingerprint = createHash('sha256').update(new (await import('node:crypto')).X509Certificate(certificate).raw).digest('hex');
    return { certificate, privateKey, fingerprint };
}
function adminPage() {
    return `<!doctype html><meta charset="utf-8"><title>AgentLink 审批</title><style>body{font:16px system-ui;max-width:48rem;margin:2rem auto;padding:0 1rem}button{margin-right:.5rem}.sas{font:700 1.35em ui-monospace}</style><h1>AgentLink 手机连接审批</h1><p>请在手机与电脑上确认 8 位数字完全一致后，再允许连接。</p><div id="requests">正在读取…</div><h2>已配对设备</h2><div id="devices"></div><script>const t=location.hash.slice(1),h={'x-agentlink-admin':t};async function call(u,o={}){return fetch(u,{...o,headers:{...h,...(o.headers||{})}})}async function refresh(){let [r,q]=await Promise.all([call('/admin/requests'),call('/admin/devices')]),d=await r.json(),v=await q.json(),e=document.querySelector('#requests'),g=document.querySelector('#devices');e.textContent='';g.textContent='';for(const x of d.requests){let p=document.createElement('p'),n=document.createElement('span');n.textContent=x.deviceName+'：两端数字 ';p.append(n);let s=document.createElement('span');s.className='sas';s.textContent=x.sas;p.append(s);if(x.status==='pending'){let a=document.createElement('button');a.textContent='两端数字一致，允许连接';a.onclick=async()=>{await call('/admin/requests/'+x.requestId+'/approve',{method:'POST'});refresh()};let b=document.createElement('button');b.textContent='拒绝';b.onclick=async()=>{await call('/admin/requests/'+x.requestId+'/deny',{method:'POST'});refresh()};p.append(a,b)}else{let z=document.createElement('span');z.textContent='（'+x.status+'）';p.append(z)}e.append(p)}if(!d.requests.length)e.textContent='暂无等待审批的手机。';for(const x of v.devices){let p=document.createElement('p'),n=document.createElement('span');n.textContent=x.name+(x.revoked?'（已撤销）':'');p.append(n);if(!x.revoked){let b=document.createElement('button');b.textContent='撤销';b.onclick=async()=>{await call('/admin/devices/'+x.id+'/revoke',{method:'POST'});refresh()};p.append(b)}g.append(p)}}refresh();setInterval(refresh,2000)</script>`;
}

/** Creates the TLS/UDP device-link perimeter. All externally supplied data is validated here. */
export async function createDeviceHost(options) {
    const bindAddress = options.bindAddress;
    if (typeof bindAddress !== 'string') throw new Error('bindAddress is required');
    const hostName = String(options.name || 'AgentLink Host').slice(0, 80);
    const stateDirectory = join(options.hapiHome, 'device-link');
    await mkdir(stateDirectory, { recursive: true, mode: 0o700 }); await chmod(stateDirectory, 0o700);
    const { certificate, privateKey, fingerprint } = await ensureCertificate(stateDirectory, bindAddress, options.owner || hostName);
    const recordsFile = join(stateDirectory, 'devices.json');
    const persisted = await loadJson(recordsFile, { devices: [], adminToken: encoded(randomBytes(32)) });
    const validDevice = value => value && typeof value === 'object' && validNonce(value.id) && deviceName(value.name) && /^[a-f0-9]{64}$/.test(value.tokenHash) && typeof value.revoked === 'boolean';
    if (!Array.isArray(persisted.devices) || !persisted.devices.every(validDevice) || !validNonce(persisted.adminToken)) throw new Error('AgentLink device state failed integrity checks: invalid schema');
    const state = { devices: persisted.devices, adminToken: persisted.adminToken };
    if (!existsSync(recordsFile)) await atomicJson(recordsFile, state);
    let saveTail = Promise.resolve();
    const updateDevices = change => {
        const write = saveTail.then(async () => {
            const devices = change(state.devices);
            await atomicJson(recordsFile, { ...state, devices });
            state.devices = devices;
        });
        saveTail = write.catch(() => {});
        return write;
    };
    const requests = new Map(); const challenges = new Map(); const challengeRates = new Map();
    const now = () => options.now?.() ?? Date.now();
    const expired = entry => entry.expiresAt <= now();
    const clean = () => { for (const [id, entry] of requests) if (expired(entry)) requests.delete(id); for (const [id, entry] of challenges) if (expired(entry)) challenges.delete(id); for (const [ip, times] of challengeRates) { const recent = times.filter(time => now() - time < 60_000); if (recent.length) challengeRates.set(ip, recent); else challengeRates.delete(ip); } };
    const tlsPort = options.tlsPort ?? 3107; const discoveryPort = options.discoveryPort ?? 3108; const adminPort = options.adminPort ?? 3109;
    const upstream = new URL(options.hubUrl);
    if (!options.cliApiToken) throw new Error('cliApiToken is required');
    const authorizeDevice = request => {
        const value = request.headers['x-agentlink-device-token'];
        if (typeof value !== 'string') return undefined;
        const record = state.devices.find(device => !device.revoked && equal(device.tokenHash, tokenHash(value)));
        return record;
    };
    async function proxy(request, response, path) {
        if (!authorizeDevice(request)) return fail(response, 401, 'Device credential required');
        let incoming; try { incoming = await body(request); } catch (error) { return fail(response, error.status || 400, error.message); }
        const target = new URL(path, upstream); let outgoingBody;
        if (path === '/api/auth') outgoingBody = JSON.stringify({ accessToken: options.cliApiToken });
        else if (['GET', 'HEAD'].includes(request.method)) outgoingBody = undefined;
        else outgoingBody = JSON.stringify(incoming);
        try {
            const timeout = /^\/api\/machines\/[^/]+\/spawn(?:\?|$)/.test(path) ? 95_000 : 30_000;
            const upstreamResponse = await fetch(target, { method: request.method, redirect: 'error', headers: { Accept: request.headers.accept || 'application/json', ...(typeof request.headers.authorization === 'string' ? { Authorization: request.headers.authorization } : {}), ...(outgoingBody ? { 'Content-Type': 'application/json' } : {}) }, body: outgoingBody, signal: AbortSignal.timeout(timeout) });
            const contentLength = Number(upstreamResponse.headers.get('content-length') || 0);
            if (contentLength > maxResponseBytes) return fail(response, 502, 'Upstream response too large');
            response.writeHead(upstreamResponse.status, { 'Content-Type': upstreamResponse.headers.get('content-type') || 'application/octet-stream', 'Cache-Control': 'no-store' });
            let count = 0;
            if (!upstreamResponse.body) return response.end();
            for await (const chunk of upstreamResponse.body) { count += chunk.length; if (count > maxResponseBytes) { response.destroy(); return; } response.write(chunk); }
            response.end();
        } catch {
            if (response.headersSent) response.destroy();
            else fail(response, 502, 'Upstream unavailable');
        }
    }
    const tlsServer = createHttpsServer({ key: privateKey, cert: certificate, handshakeTimeout: 10_000 }, async (request, response) => {
        request.setTimeout(15_000, () => request.destroy());
        clean(); const targetUrl = new URL(request.url, 'https://device'); const path = targetUrl.pathname; const pathWithQuery = `${path}${targetUrl.search}`;
        try {
            if (request.method === 'GET' && path === '/link/info') return json(response, 200, { id: fingerprint, name: hostName, fingerprint });
            if (request.method === 'POST' && path === '/link/challenge') {
                if (challenges.size >= 32) return fail(response, 429, 'Too many pending challenges');
                const source = request.socket.remoteAddress || 'unknown'; const issued = challengeRates.get(source) || [];
                if (issued.length >= 8) return fail(response, 429, 'Challenge rate limit exceeded');
                issued.push(now()); challengeRates.set(source, issued);
                const requestId = encoded(randomBytes(32)); const serverNonce = encoded(randomBytes(32)); const expiresAt = now() + requestTtlMs;
                challenges.set(requestId, { requestId, serverNonce, expiresAt });
                return json(response, 200, { requestId, commitment: commitment(fingerprint, serverNonce, requestId) });
            }
            if (request.method === 'POST' && path === '/link/requests') {
                const input = await body(request);
                if (!validNonce(input.requestId) || !validNonce(input.clientNonce) || !deviceName(input.deviceName)) return fail(response, 400, 'Invalid pairing request');
                const existing = requests.get(input.requestId);
                if (existing && !expired(existing) && existing.clientNonce === input.clientNonce) return json(response, 200, existing.public);
                const challenge = challenges.get(input.requestId);
                if (!challenge || expired(challenge) || challenge.used) return fail(response, 410, 'Pairing challenge expired');
                if (requests.size >= 16) return fail(response, 429, 'Too many pending requests');
                challenge.used = true;
                const entry = { requestId: input.requestId, clientNonce: input.clientNonce, deviceName: input.deviceName, serverNonce: challenge.serverNonce, expiresAt: challenge.expiresAt, status: 'pending' };
                entry.public = { serverNonce: entry.serverNonce, expiresAt: entry.expiresAt, sas: requestSas(fingerprint, entry.serverNonce, entry.clientNonce, entry.requestId) };
                requests.set(entry.requestId, entry); return json(response, 200, entry.public);
            }
            const poll = path.match(/^\/link\/requests\/([A-Za-z0-9_-]{43})\/poll$/);
            if (request.method === 'POST' && poll) {
                const input = await body(request); const entry = requests.get(poll[1]);
                if (!entry || expired(entry)) return json(response, 200, { status: 'expired' });
                if (!validNonce(input.clientNonce) || input.clientNonce !== entry.clientNonce) return fail(response, 403, 'Pairing request does not match device');
                return json(response, 200, entry.status === 'approved' ? { status: 'approved', deviceId: entry.deviceId, deviceToken: entry.deviceToken } : { status: entry.status });
            }
            const cancel = path.match(/^\/link\/requests\/([A-Za-z0-9_-]{43})\/cancel$/);
            if (request.method === 'POST' && cancel) {
                const input = await body(request); const entry = requests.get(cancel[1]);
                if (!entry || expired(entry)) return json(response, 200, { status: 'expired' });
                if (!validNonce(input.clientNonce) || input.clientNonce !== entry.clientNonce) return fail(response, 403, 'Pairing request does not match device');
                if (entry.status === 'approved') {
                    await updateDevices(devices => devices.map(device => device.id === entry.deviceId ? { ...device, revoked: true } : device));
                    delete entry.deviceToken;
                }
                if (entry.status !== 'denied') entry.status = 'denied';
                return json(response, 200, { status: 'denied' });
            }
            if ((request.method === 'GET' && path === '/health') || path === '/api/auth' || path.startsWith('/api/')) return await proxy(request, response, pathWithQuery);
            fail(response, 404, 'Not found');
        } catch (error) {
            if (response.headersSent) response.destroy();
            else fail(response, error.status || 500, error.message || 'Internal error');
        }
    });
    tlsServer.maxConnections = 64;
    tlsServer.headersTimeout = 15_000;
    tlsServer.requestTimeout = 15_000;
    tlsServer.keepAliveTimeout = 5_000;
    const http = await import('node:http');
    let actualAdminPort = adminPort;
    const localAdmin = http.createServer(async (request, response) => {
        const host = String(request.headers.host || ''); const origin = request.headers.origin;
        if (!/^127\.0\.0\.1(?::\d+)?$/.test(host) || (origin && origin !== `http://127.0.0.1:${actualAdminPort}`)) return fail(response, 403, 'Local admin origin required');
        try {
            const path = new URL(request.url, 'http://local').pathname; clean();
            if (request.method === 'GET' && path === '/') { response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }); return response.end(adminPage()); }
            if (!equal(request.headers['x-agentlink-admin'], state.adminToken)) return fail(response, 403, 'Local admin authorization required');
            if (request.method === 'GET' && path === '/admin/requests') return json(response, 200, { requests: [...requests.values()].filter(entry => !expired(entry)).map(entry => ({ requestId: entry.requestId, deviceName: entry.deviceName, sas: entry.public.sas, status: entry.status })) });
            if (request.method === 'GET' && path === '/admin/devices') return json(response, 200, { devices: state.devices.map(device => ({ id: device.id, name: device.name, revoked: device.revoked })) });
            const action = path.match(/^\/admin\/requests\/([A-Za-z0-9_-]{43})\/(approve|deny)$/);
            if (request.method === 'POST' && action) {
                const entry = requests.get(action[1]); if (!entry || expired(entry)) return fail(response, 404, 'Request not found');
                if (action[2] === 'approve' && entry.status === 'pending') { const id = encoded(randomBytes(32)); const token = encoded(randomBytes(32)); await updateDevices(devices => [...devices, { id, name: entry.deviceName, tokenHash: tokenHash(token), revoked: false }]); entry.status = 'approved'; entry.deviceId = id; entry.deviceToken = token; }
                if (action[2] === 'deny' && entry.status === 'pending') entry.status = 'denied';
                return json(response, 200, { status: entry.status });
            }
            const deviceRevoke = path.match(/^\/admin\/devices\/([A-Za-z0-9_-]{43})\/revoke$/);
            if (request.method === 'POST' && deviceRevoke) { const exists = state.devices.some(value => value.id === deviceRevoke[1]); if (!exists) return fail(response, 404, 'Device not found'); await updateDevices(devices => devices.map(device => device.id === deviceRevoke[1] ? { ...device, revoked: true } : device)); return json(response, 200, { revoked: true }); }
            fail(response, 404, 'Not found');
        } catch (error) { fail(response, 500, 'Local admin update failed'); }
    });
    const udp = createSocket('udp4'); const udpReply = createSocket('udp4');
    // 诊断开关：AGENTLINK_UDP_TRACE=1 时打印发现包的处理过程，便于排查手机扫不到电脑的问题。
    const traceUdp = process.env.AGENTLINK_UDP_TRACE === '1';
    const trace = note => { if (traceUdp) console.log(`[discovery] ${note}`); };
    udp.on('message', (message, remote) => { try { if (message.length > 2048) { trace(`丢弃超大包 ${message.length}B，来自 ${remote.address}:${remote.port}`); return; } const packet = JSON.parse(message); if (!privateAddress(remote.address)) { trace(`拒绝非私有来源 ${remote.address}`); return; } if (!sameSubnet(remote.address, bindAddress, options.netmask || '255.255.255.0')) { trace(`拒绝跨子网 ${remote.address}，本机 ${bindAddress}/${options.netmask || '255.255.255.0'}`); return; } if (packet?.protocol !== protocol) { trace(`协议不匹配：${String(packet?.protocol)}`); return; } if (!validNonce(packet.nonce)) { trace(`nonce 非法：${typeof packet?.nonce === 'string' ? `${packet.nonce.length} 字符` : typeof packet?.nonce}`); return; } trace(`应答 ${remote.address}:${remote.port}`); const reply = Buffer.from(JSON.stringify({ protocol, nonce: packet.nonce, hostId: fingerprint, name: hostName, port: tlsServer.address().port })); if (reply.length <= 2048) udpReply.send(reply, remote.port, remote.address); } catch (error) { trace(`解析失败：${error.message}`); } });
    const closeListening = server => new Promise(resolve => server.listening ? server.close(() => resolve()) : resolve());
    let udpBound = false; let udpReplyBound = false;
    try {
        await new Promise((resolve, reject) => tlsServer.once('error', reject).listen(tlsPort, bindAddress, resolve));
        await new Promise((resolve, reject) => localAdmin.once('error', reject).listen(adminPort, '127.0.0.1', resolve));
        await new Promise((resolve, reject) => udp.once('error', reject).bind(discoveryPort, '0.0.0.0', resolve)); udpBound = true;
        await new Promise((resolve, reject) => udpReply.once('error', reject).bind(0, bindAddress, resolve)); udpReplyBound = true;
    } catch (error) {
        if (udpBound) udp.close(); if (udpReplyBound) udpReply.close();
        await Promise.all([closeListening(tlsServer), closeListening(localAdmin)]);
        throw error;
    }
    actualAdminPort = localAdmin.address().port;
    const closeOne = server => new Promise(resolve => server.close(() => resolve()));
    return { fingerprint, hostId: fingerprint, adminUrl: `http://127.0.0.1:${actualAdminPort}/#${state.adminToken}`, addresses: { tls: tlsServer.address(), discovery: udp.address(), admin: localAdmin.address() }, close: async () => { udp.close(); udpReply.close(); await Promise.all([closeOne(tlsServer), closeOne(localAdmin)]); } };
}
