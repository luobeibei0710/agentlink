import { isIP } from 'node:net';

const VIRTUAL_INTERFACE = /^(?:awdl|bridge|docker|gif|ipsec|llw|lo|ppp|tap|tun|utun|veth|vmnet)/i;

export function parseHostArguments(args) {
    const lan = args.includes('--lan');
    const lanIpIndex = args.indexOf('--lan-ip');
    const lanIp = lanIpIndex === -1 ? undefined : args[lanIpIndex + 1];
    if (lanIpIndex !== -1 && (!lan || !lanIp || lanIp.startsWith('--'))) throw new Error('--lan-ip requires --lan and an address');
    const isLanIpArgument = index => lanIpIndex >= 0 && (index === lanIpIndex || index === lanIpIndex + 1);
    const workspaceArguments = args.filter((arg, index) => arg !== '--lan' && !isLanIpArgument(index) && !arg.startsWith('--'));
    if (workspaceArguments.length > 1) throw new Error('Only one workspace path is supported');
    return { lan, lanIp, workspaceArgument: workspaceArguments[0] };
}

export function isRfc1918Address(address) {
    if (isIP(address) !== 4) return false;
    const [first, second] = address.split('.').map(Number);
    return first === 10 || (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168);
}

export function collectLanCandidates(interfaces) {
    return Object.entries(interfaces)
        .flatMap(([name, addresses]) => (addresses ?? []).map(address => ({ name, ...address })))
        .filter(address => !address.internal && address.family === 'IPv4' && isRfc1918Address(address.address))
        .map(({ name, address }) => ({ name, address, virtual: VIRTUAL_INTERFACE.test(name) }))
        .sort((a, b) => a.name.localeCompare(b.name) || a.address.localeCompare(b.address));
}

export function formatLanCandidates(candidates) {
    return candidates.map(candidate => `${candidate.name}: ${candidate.address}${candidate.virtual ? ' (virtual/VPN)' : ''}`).join(', ');
}

/**
 * Pick a LAN address only when it is unambiguous. Virtual interfaces are never
 * selected automatically: an operator can still opt in with --lan-ip.
 */
export function resolveLanAddress(interfaces, explicitAddress) {
    const candidates = collectLanCandidates(interfaces);
    if (explicitAddress) {
        const selected = candidates.find(candidate => candidate.address === explicitAddress);
        if (!selected) {
            throw new Error(`--lan-ip must be an RFC1918 IPv4 address assigned to this computer. Candidates: ${formatLanCandidates(candidates) || 'none'}`);
        }
        return { selected, candidates };
    }

    const physicalCandidates = candidates.filter(candidate => !candidate.virtual);
    if (physicalCandidates.length === 1) return { selected: physicalCandidates[0], candidates };
    if (physicalCandidates.length === 0) {
        throw new Error(`No physical RFC1918 IPv4 LAN address found. Candidates: ${formatLanCandidates(candidates) || 'none'}`);
    }
    throw new Error(`Multiple physical RFC1918 LAN addresses found. Choose one with --lan-ip. Candidates: ${formatLanCandidates(candidates)}`);
}

export function companionBindUrl(hubUrl, accessToken) {
    const params = new URLSearchParams({ hub: hubUrl, code: accessToken });
    return `hapicompanion://bind?${params.toString()}`;
}

export function pairingHtml({ hubUrl, companionUrl, qrDataUrl }) {
    const escape = value => value.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
    return `<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AgentLink 局域网配对</title><style>body{font:16px system-ui,sans-serif;max-width:38rem;margin:3rem auto;padding:0 1rem;color:#18212f}img{width:min(80vw,20rem);image-rendering:pixelated}code{word-break:break-all}</style>
<h1>AgentLink 局域网配对</h1><p>使用 AgentLink 扫描二维码。此页面含有访问电脑会话的配对码，请勿分享。</p>
<img src="${escape(qrDataUrl)}" alt="AgentLink 配对二维码"><p>Hub：<code>${escape(hubUrl)}</code></p><p>无法扫码时，在 App 中粘贴：<code>${escape(companionUrl)}</code></p></html>`;
}
