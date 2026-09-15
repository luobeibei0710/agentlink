import { readdirSync, readFileSync, statSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { basename, join } from 'node:path'
import { homedir } from 'node:os'
import { AGENT_MESSAGE_PAYLOAD_TYPE } from '@hapi/protocol'

const DEFAULT_CODEBUDDY_SESSION_SCAN_LIMIT = 200

/**
 * CodeBuddy CLI 把每个会话写成 `<CodeBuddyHome>/projects/<项目目录>/<会话 id>.jsonl`。
 * 文件行是 JSON 记录，`message`/`function_call` 等类型与本模块的导入结构一一对应。
 */
export type CodeBuddyImportedMessageContent = {
    role: 'user'
    content: { type: 'text'; text: string }
    meta: { sentFrom: 'cli' }
} | {
    role: 'agent'
    content: { type: typeof AGENT_MESSAGE_PAYLOAD_TYPE; data: unknown }
    meta: { sentFrom: 'cli' }
}

export type LocalCodeBuddySessionSummary = {
    id: string
    title: string
    lastUserMessage?: string | null
    cwd?: string | null
    file: string
    modifiedAt: number
    messageCount: number
}

export type LocalCodeBuddyMessage = {
    localId: string
    createdAt: number | null
    content: CodeBuddyImportedMessageContent
}

export type LocalCodeBuddySessionWithMessages = LocalCodeBuddySessionSummary & {
    messages: LocalCodeBuddyMessage[]
}

function asRecord(value: unknown): Record<string, unknown> | null {
    return value !== null && typeof value === 'object' && !Array.isArray(value)
        ? value as Record<string, unknown>
        : null
}

function asString(value: unknown): string | null {
    return typeof value === 'string' && value.length > 0 ? value : null
}

function truncateText(value: string, maxLength: number): string {
    return value.length > maxLength ? `${value.slice(0, maxLength - 1)}…` : value
}

/**
 * 判断用户消息是否只是宿主注入的内部提示。
 *
 * 这类内容（系统提醒、环境上下文、AGENTS.md 说明）由工具自动写入，不能作为
 * 会话标题或摘要展示。
 *
 * @param text 候选文本
 * @returns 属于内部注入内容时返回 true
 */
function shouldIgnoreSyntheticUserMessage(text: string): boolean {
    const normalized = text.trim()
    return normalized.startsWith('<system-reminder')
        || normalized.startsWith('# AGENTS.md instructions')
        || normalized.startsWith('<environment_context>')
}

/** 从 `content: [{ type, text }]` 形态中取出文本，兼容字符串与单对象写法。 */
function extractContentText(value: unknown): string {
    if (typeof value === 'string') return value.trim()
    if (Array.isArray(value)) {
        return value.map((item) => {
            const record = asRecord(item)
            return record && typeof record.text === 'string' ? record.text : null
        }).filter((part): part is string => Boolean(part)).join(' ').trim()
    }
    const record = asRecord(value)
    return record && typeof record.text === 'string' ? record.text.trim() : ''
}

function getCodeBuddyHome(): string {
    return process.env.CODEBUDDY_HOME?.trim() || join(homedir(), '.codebuddy')
}

/**
 * 判断会话是否属于一次性工作目录。
 *
 * 临时目录（系统 temp、ACP 联调用的 /private/var/folders 等）里的会话是测试或
 * 单次运行产物，进入历史列表只会造成噪音，因此在扫描阶段直接排除。
 *
 * @param cwd 会话记录中的工作目录，可能为空
 * @param file 会话文件路径，用于 cwd 缺失时的兜底判断
 * @returns 属于临时工作目录时返回 true
 */
function isEphemeralWorkspace(cwd: string | null, file: string): boolean {
    const value = cwd ?? file
    return value.startsWith('/private/var/folders/')
        || value.startsWith('/var/folders/')
        || value.startsWith('/tmp/')
        || value.startsWith('/private/tmp/')
}

/**
 * 递归收集 CodeBuddy 会话文件。
 *
 * @param root 起始目录
 * @param files 收集结果（原地追加）
 */
function collectJsonlFiles(root: string, files: string[]): void {
    let entries: import('node:fs').Dirent[]
    try {
        entries = readdirSync(root, { withFileTypes: true })
    } catch {
        return
    }
    for (const entry of entries) {
        const fullPath = join(root, entry.name)
        if (entry.isDirectory()) collectJsonlFiles(fullPath, files)
        else if (entry.isFile() && fullPath.toLowerCase().endsWith('.jsonl')) files.push(fullPath)
    }
}

function buildImportedUserMessage(text: string): CodeBuddyImportedMessageContent {
    return { role: 'user', content: { type: 'text', text }, meta: { sentFrom: 'cli' } }
}

function buildImportedAgentMessage(data: unknown): CodeBuddyImportedMessageContent {
    return { role: 'agent', content: { type: AGENT_MESSAGE_PAYLOAD_TYPE, data }, meta: { sentFrom: 'cli' } }
}

function parseToolArguments(value: unknown): unknown {
    if (typeof value !== 'string') return value
    const trimmed = value.trim()
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return value
    try { return JSON.parse(trimmed) } catch { return value }
}

/**
 * 把一条 CodeBuddy jsonl 记录转换成可导入的消息。
 *
 * 只保留对话与工具调用记录；`reasoning`、`file-history-snapshot` 等内部状态
 * 不进入历史对话，避免污染客户端视图。
 *
 * @param record 单行解析后的记录
 * @param index 记录在文件中的序号，用于生成稳定的 localId 兜底
 * @returns 可导入消息（含 localId 与时间），无法识别时返回 null
 */
function convertCodeBuddyRecord(record: Record<string, unknown>, index: number): LocalCodeBuddyMessage | null {
    const type = asString(record.type)
    const recordId = asString(record.id) ?? `line-${index}`
    const createdAt = typeof record.timestamp === 'number' ? record.timestamp : null
    if (!type) return null

    if (type === 'message') {
        const role = asString(record.role)
        const text = extractContentText(record.content)
        if (!text) return null
        if (role === 'user') return { localId: recordId, createdAt, content: buildImportedUserMessage(text) }
        if (role === 'assistant') {
            return { localId: recordId, createdAt, content: buildImportedAgentMessage({ type: 'message', message: text, id: randomUUID() }) }
        }
        return null
    }

    if (type === 'function_call') {
        const name = asString(record.name)
        const callId = asString(record.callId) ?? asString(record.call_id) ?? recordId
        if (!name) return null
        return {
            localId: recordId,
            createdAt,
            content: buildImportedAgentMessage({
                type: 'tool-call',
                name,
                callId,
                input: parseToolArguments(record.arguments),
                id: randomUUID()
            })
        }
    }

    if (type === 'function_call_result') {
        const callId = asString(record.callId) ?? asString(record.call_id)
        if (!callId) return null
        return {
            localId: recordId,
            createdAt,
            content: buildImportedAgentMessage({ type: 'tool-call-result', callId, output: record.output, id: randomUUID() })
        }
    }

    return null
}

/**
 * 解析单个 CodeBuddy 会话文件。
 *
 * @param filePath 会话 jsonl 路径
 * @param includeMessages 是否需要完整消息（列表摘要时传 false 以跳过转换）
 * @returns 会话摘要；文件为空、无有效记录或属于临时目录时返回 null
 */
function parseCodeBuddySession(
    filePath: string,
    includeMessages: boolean
): LocalCodeBuddySessionWithMessages | LocalCodeBuddySessionSummary | null {
    let content: string
    try { content = readFileSync(filePath, 'utf-8') } catch { return null }
    const lines = content.split(/\r?\n/).filter(Boolean)
    if (lines.length === 0) return null

    const id = basename(filePath).replace(/\.jsonl$/i, '')
    let cwd: string | null = null
    let summaryTitle: string | null = null
    let firstUserMessage: string | null = null
    let lastUserMessage: string | null = null
    let messageCount = 0
    const messages: LocalCodeBuddyMessage[] = []

    for (let index = 0; index < lines.length; index += 1) {
        let record: Record<string, unknown> | null = null
        try { record = asRecord(JSON.parse(lines[index])) } catch { continue }
        if (!record) continue
        if (!cwd) cwd = asString(record.cwd)
        if (!summaryTitle && record.type === 'summary') {
            const candidate = asString(record.summary)
            if (candidate && !shouldIgnoreSyntheticUserMessage(candidate)) summaryTitle = candidate
        }
        if (record.type === 'message' && record.role === 'user') {
            const text = extractContentText(record.content)
            if (text && !shouldIgnoreSyntheticUserMessage(text)) {
                if (!firstUserMessage) firstUserMessage = text
                lastUserMessage = text
            }
        }
        // 摘要模式同样要统计消息条数，客户端用它判断会话是否有对话内容。
        const message = convertCodeBuddyRecord(record, index)
        if (message) {
            messageCount += 1
            if (includeMessages) messages.push(message)
        }
    }

    if (!firstUserMessage && !summaryTitle) return null
    if (isEphemeralWorkspace(cwd, filePath)) return null

    let modifiedAt = Date.now()
    try { modifiedAt = statSync(filePath).mtimeMs } catch { /* 使用当前时间兜底 */ }

    const summary: LocalCodeBuddySessionSummary = {
        id,
        title: summaryTitle
            ? truncateText(summaryTitle, 80)
            : firstUserMessage
                ? truncateText(firstUserMessage, 80)
                : basename(cwd ?? id),
        lastUserMessage: lastUserMessage ? truncateText(lastUserMessage, 140) : null,
        cwd,
        file: filePath,
        modifiedAt,
        messageCount
    }
    return includeMessages ? { ...summary, messages } : summary
}

function collectCodeBuddySessionFiles(): string[] {
    const projectsRoot = join(getCodeBuddyHome(), 'projects')
    const files: string[] = []
    collectJsonlFiles(projectsRoot, files)
    return files
}

function listLocalCodeBuddySessions(includeMessages: false, limit?: number): LocalCodeBuddySessionSummary[]
function listLocalCodeBuddySessions(includeMessages: true, limit?: number): LocalCodeBuddySessionWithMessages[]
function listLocalCodeBuddySessions(
    includeMessages: boolean,
    limit = DEFAULT_CODEBUDDY_SESSION_SCAN_LIMIT
): Array<LocalCodeBuddySessionSummary | LocalCodeBuddySessionWithMessages> {
    const deduped = new Map<string, LocalCodeBuddySessionSummary | LocalCodeBuddySessionWithMessages>()
    for (const file of collectCodeBuddySessionFiles()) {
        // 空文件代表仅创建、未产生对话的会话，读它没有意义。
        try { if (statSync(file).size === 0) continue } catch { continue }
        const session = parseCodeBuddySession(file, includeMessages)
        if (!session) continue
        const previous = deduped.get(session.id)
        if (!previous || previous.modifiedAt < session.modifiedAt) deduped.set(session.id, session)
    }
    return Array.from(deduped.values())
        .sort((a, b) => b.modifiedAt - a.modifiedAt)
        .slice(0, limit)
}

/** 列出 CodeBuddy 历史会话摘要，按最近修改时间倒序。 */
export function listLocalCodeBuddySessionSummaries(
    limit = DEFAULT_CODEBUDDY_SESSION_SCAN_LIMIT
): LocalCodeBuddySessionSummary[] {
    return listLocalCodeBuddySessions(false, limit)
}

/** 列出 CodeBuddy 历史会话并包含完整消息，供导入使用。 */
export function listLocalCodeBuddySessionsWithMessages(
    limit = DEFAULT_CODEBUDDY_SESSION_SCAN_LIMIT
): LocalCodeBuddySessionWithMessages[] {
    return listLocalCodeBuddySessions(true, limit)
}

/** 按会话 id 精确读取 CodeBuddy 历史（含完整消息）。 */
export function listLocalCodeBuddySessionsWithMessagesByIds(ids: Set<string>): LocalCodeBuddySessionWithMessages[] {
    if (ids.size === 0) return []
    const deduped = new Map<string, LocalCodeBuddySessionWithMessages>()
    for (const file of collectCodeBuddySessionFiles()) {
        const id = basename(file).replace(/\.jsonl$/i, '')
        if (!ids.has(id)) continue
        try { if (statSync(file).size === 0) continue } catch { continue }
        const session = parseCodeBuddySession(file, true)
        if (!session || !('messages' in session)) continue
        const previous = deduped.get(session.id)
        if (!previous || previous.modifiedAt < session.modifiedAt) deduped.set(session.id, session)
    }
    return Array.from(deduped.values()).sort((a, b) => b.modifiedAt - a.modifiedAt)
}
