import { Hono } from 'hono'
import type { CodeBuddyLocalSessionSummary, CodeBuddyLocalSessionWithMessages } from '@hapi/protocol/apiTypes'
import type { Metadata } from '@hapi/protocol/types'
import type { Store, StoredMessage, StoredSession } from '../../store'
import { truncateOversizedMessageContent } from '../../store/contentCodec'
import type { Machine, SyncEngine } from '../../sync/syncEngine'
import type { WebAppEnv } from '../middleware/auth'

const importLocks = new Map<string, Promise<CodeBuddyImportResult>>()

export type CodeBuddySessionListItem = CodeBuddyLocalSessionSummary & {
    hapiSessionId?: string
}

export type CodeBuddyImportResult = {
    codebuddySessionId: string
    hapiSessionId?: string
    action?: 'created' | 'updated' | 'unchanged'
    appended?: number
    error?: { code: string; message: string }
}

function asRecord(value: unknown): Record<string, unknown> | null {
    return value !== null && typeof value === 'object' && !Array.isArray(value)
        ? value as Record<string, unknown>
        : null
}

function storedMetadata(session: StoredSession): Record<string, unknown> {
    return asRecord(session.metadata) ?? {}
}

function resolveMachine(
    engine: SyncEngine | null,
    namespace: string,
    requestedMachineId?: string | null
): Machine | null {
    if (!engine) return null
    const online = engine.getOnlineMachinesByNamespace(namespace)
    if (requestedMachineId) return online.find((machine) => machine.id === requestedMachineId) ?? null
    return online[0] ?? null
}

function importedSessionsByNativeId(
    store: Store,
    namespace: string,
    machineId: string
): Map<string, StoredSession> {
    const imported = new Map<string, StoredSession>()
    for (const session of store.sessions.getSessionsByNamespace(namespace)) {
        const metadata = storedMetadata(session)
        const nativeId = metadata.codebuddySessionId
        if (metadata.flavor !== 'codebuddy'
            || metadata.machineId !== machineId
            || typeof nativeId !== 'string'
            || imported.has(nativeId)) continue
        imported.set(nativeId, session)
    }
    return imported
}

/**
 * 构建导入会话的元数据。
 *
 * `codebuddySessionId` 是恢复会话的必需字段：Runner 会把它作为 `--resume` 的原生
 * 会话 id 传给 CodeBuddy ACP，由 `session/load` 重新加载对话。`lifecycleState` 使用
 * `imported`，使会话既不出现在归档区，也能被 reopen 直接恢复。
 *
 * @param transcript 本地 CodeBuddy 会话（含消息）
 * @param machine 会话所属的在线机器
 * @param existing 已有元数据，用于增量导入时保留字段
 * @returns 合并后的会话元数据
 */
function buildMetadata(
    transcript: CodeBuddyLocalSessionWithMessages,
    machine: Machine,
    existing: Record<string, unknown>
): Metadata {
    const now = Date.now()
    const summaryText = transcript.lastUserMessage ?? transcript.title
    return {
        ...existing,
        path: transcript.cwd ?? (typeof existing.path === 'string' ? existing.path : machine.id),
        host: typeof existing.host === 'string' ? existing.host : (machine.metadata?.host ?? machine.id),
        os: typeof existing.os === 'string' ? existing.os : (machine.metadata?.platform ?? process.platform),
        name: typeof existing.name === 'string' ? existing.name : transcript.title,
        summary: summaryText ? { text: summaryText, updatedAt: now } : existing.summary,
        machineId: machine.id,
        flavor: 'codebuddy',
        codebuddySessionId: transcript.id,
        lifecycleState: typeof existing.lifecycleState === 'string' ? existing.lifecycleState : 'imported',
        lifecycleStateSince: typeof existing.lifecycleStateSince === 'number' ? existing.lifecycleStateSince : now
    } as Metadata
}

function updateMetadataWithRetry(
    store: Store,
    sessionId: string,
    namespace: string,
    transform: (metadata: Record<string, unknown>) => Metadata
): Metadata {
    for (let attempt = 0; attempt < 5; attempt += 1) {
        const current = store.sessions.getSessionByNamespace(sessionId, namespace)
        if (!current) throw new Error('Imported HAPI session disappeared')
        const next = transform(storedMetadata(current))
        const result = store.sessions.updateSessionMetadata(
            sessionId,
            next,
            current.metadataVersion,
            namespace,
            { touchUpdatedAt: false }
        )
        if (result.result === 'success') return next
        if (result.result === 'error') throw new Error('Failed to persist CodeBuddy import metadata')
    }
    throw new Error('CodeBuddy import metadata changed concurrently')
}

function emitImportedMessages(engine: SyncEngine, sessionId: string, messages: StoredMessage[]): void {
    for (const message of messages) {
        engine.handleRealtimeEvent({
            type: 'message-received',
            sessionId,
            message: {
                id: message.id,
                seq: message.seq,
                localId: message.localId,
                content: message.content,
                createdAt: message.createdAt,
                invokedAt: message.invokedAt
            }
        })
    }
}

export function importCodeBuddySession(options: {
    store: Store
    engine: SyncEngine
    namespace: string
    machine: Machine
    transcript: CodeBuddyLocalSessionWithMessages
    existingSession?: StoredSession | null
}): CodeBuddyImportResult {
    const { store, engine, namespace, machine, transcript, existingSession } = options
    let stored = existingSession
        ?? importedSessionsByNativeId(store, namespace, machine.id).get(transcript.id)
        ?? null
    const created = !stored

    if (!stored) {
        stored = store.sessions.getOrCreateSession(
            `codebuddy-import:${machine.id}:${transcript.id}`,
            buildMetadata(transcript, machine, {}),
            {},
            namespace
        )
    } else {
        updateMetadataWithRetry(store, stored.id, namespace, (metadata) => buildMetadata(transcript, machine, metadata))
    }

    const existingLocalIds = new Set(store.messages.getAllMessages(stored.id)
        .map((message) => message.localId)
        .filter((localId): localId is string => Boolean(localId)))
    const appended: StoredMessage[] = []
    for (const source of transcript.messages) {
        // localId 以来源会话为前缀，避免不同 CodeBuddy 会话的同名记录互相覆盖。
        const localId = `codebuddy:${transcript.id}:${source.localId}`
        if (existingLocalIds.has(localId)) continue
        const result = store.messages.addImportedMessage(
            stored.id,
            truncateOversizedMessageContent(source.content),
            localId,
            source.createdAt ?? Date.now()
        )
        if (result.inserted) appended.push(result.message)
    }

    engine.recordSessionActivity(stored.id, appended.at(-1)?.createdAt ?? transcript.modifiedAt)
    emitImportedMessages(engine, stored.id, appended)
    engine.handleRealtimeEvent({ type: 'session-updated', sessionId: stored.id })

    return {
        codebuddySessionId: transcript.id,
        hapiSessionId: stored.id,
        action: created ? 'created' : appended.length > 0 ? 'updated' : 'unchanged',
        appended: appended.length
    }
}

async function importWithLock(key: string, work: () => CodeBuddyImportResult): Promise<CodeBuddyImportResult> {
    const prior = importLocks.get(key)
    if (prior) return prior
    const current = Promise.resolve().then(work)
    importLocks.set(key, current)
    try {
        return await current
    } finally {
        if (importLocks.get(key) === current) importLocks.delete(key)
    }
}

export function createCodeBuddySessionRoutes(options: {
    store: Store
    getSyncEngine: () => SyncEngine | null
}): Hono<WebAppEnv> {
    const app = new Hono<WebAppEnv>()

    app.get('/codebuddy/sessions', async (c) => {
        const namespace = c.get('namespace')
        const engine = options.getSyncEngine()
        const machine = resolveMachine(engine, namespace, c.req.query('machineId')?.trim() || null)
        if (!engine || !machine) {
            return c.json({ success: false, error: 'No online machine available for CodeBuddy history import', sessions: [] }, 503)
        }
        const result = await engine.listCodeBuddySessionsForMachine(machine.id, c.req.query('cwd')?.trim() || null)
        if (!result.success) {
            return c.json({ success: false, error: result.error, sessions: [], machineId: machine.id }, 503)
        }
        const imported = importedSessionsByNativeId(options.store, namespace, machine.id)
        const sessions: CodeBuddySessionListItem[] = result.sessions.map((summary) => {
            const existing = imported.get(summary.id)
            return { ...summary, ...(existing ? { hapiSessionId: existing.id } : {}) }
        })
        return c.json({ success: true, sessions, machineId: machine.id })
    })

    app.post('/codebuddy/import-sessions', async (c) => {
        const body = asRecord(await c.req.json().catch(() => null))
        const sessionIds = Array.isArray(body?.sessionIds)
            ? body.sessionIds
                .filter((id): id is string => typeof id === 'string' && id.trim().length > 0)
                .map((id) => id.trim())
            : []
        if (sessionIds.length === 0) {
            return c.json({ success: false, error: 'No CodeBuddy sessions selected', results: [] }, 400)
        }
        const uniqueSessionIds = [...new Set(sessionIds)]
        const namespace = c.get('namespace')
        const engine = options.getSyncEngine()
        const machine = resolveMachine(engine, namespace, typeof body?.machineId === 'string' ? body.machineId.trim() : null)
        if (!engine || !machine) {
            return c.json({ success: false, error: 'No online machine available for CodeBuddy history import', results: [] }, 503)
        }
        const remote = await engine.listCodeBuddySessionsForMachine(
            machine.id,
            typeof body?.cwd === 'string' ? body.cwd.trim() : null,
            uniqueSessionIds
        )
        if (!remote.success) {
            return c.json({ success: false, error: remote.error, results: [], machineId: machine.id }, 503)
        }
        const byId = new Map(remote.sessions
            .filter((session): session is CodeBuddyLocalSessionWithMessages => 'messages' in session)
            .map((session) => [session.id, session]))
        const imported = importedSessionsByNativeId(options.store, namespace, machine.id)
        const results: CodeBuddyImportResult[] = []
        for (const sessionId of uniqueSessionIds) {
            const transcript = byId.get(sessionId)
            if (!transcript) {
                results.push({ codebuddySessionId: sessionId, error: { code: 'not_found', message: 'CodeBuddy session transcript not found' } })
                continue
            }
            results.push(await importWithLock(
                `${namespace}:${machine.id}:${sessionId}`,
                () => importCodeBuddySession({
                    store: options.store,
                    engine,
                    namespace,
                    machine,
                    transcript,
                    existingSession: imported.get(sessionId) ?? null
                })
            ))
        }
        return c.json({ success: results.every((result) => !result.error), results, machineId: machine.id })
    })

    return app
}
