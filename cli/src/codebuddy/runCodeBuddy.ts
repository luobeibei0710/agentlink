import { bootstrapExistingSession, bootstrapSession } from '@/agent/sessionFactory'
import type { PermissionMode } from '@hapi/protocol/types'
import { createRunnerLifecycle, setControlledByUser } from '@/agent/runnerLifecycle'
import { registerKillSessionHandler } from '@/claude/registerKillSessionHandler'
import type { AgentState } from '@/api/types'
import { MessageQueue2 } from '@/utils/MessageQueue2'
import { hashObject } from '@/utils/deterministicJson'
import { formatMessageWithAttachments } from '@/utils/attachmentFormatter'
import { getInvokedCwd } from '@/utils/invokedCwd'
import { logger } from '@/ui/logger'
import { CodeBuddyRemoteLauncher } from './codeBuddyRemoteLauncher'
import { CodeBuddySession } from './session'
import type { CodeBuddyMode } from './types'

export async function runCodeBuddy(opts: {
    startedBy?: 'runner' | 'terminal'
    startingMode?: 'remote'
    permissionMode?: PermissionMode
    resumeSessionId?: string
    existingSessionId?: string
    workingDirectory?: string
} = {}): Promise<void> {
    const workingDirectory = opts.workingDirectory ?? getInvokedCwd()
    const startedBy = opts.startedBy ?? 'terminal'
    const initialState: AgentState = {
        controlledByUser: false,
        startingMode: 'remote'
    }

    const bootstrap = opts.existingSessionId
        ? await bootstrapExistingSession({
            sessionId: opts.existingSessionId,
            flavor: 'codebuddy',
            startedBy,
            workingDirectory
        })
        : await bootstrapSession({
            flavor: 'codebuddy',
            startedBy,
            workingDirectory,
            agentState: initialState
        })
    const { api, session } = bootstrap
    setControlledByUser(session, 'remote')

    const queue = new MessageQueue2<CodeBuddyMode>((mode) => hashObject(mode))
    const sessionRef: { current: CodeBuddySession | null } = { current: null }
    const launcherRef: { current: CodeBuddyRemoteLauncher | null } = { current: null }

    session.onUserMessage((message, localId) => {
        queue.push(
            formatMessageWithAttachments(message.content.text, message.content.attachments),
            'codebuddy',
            localId
        )
    })
    session.onCancelQueuedMessage((localId) => queue.cancelByLocalId(localId))

    const lifecycle = createRunnerLifecycle({
        session,
        logTag: 'codebuddy',
        stopKeepAlive: () => sessionRef.current?.stopKeepAlive(),
        onBeforeClose: () => launcherRef.current?.kill()
    })
    lifecycle.registerProcessHandlers()
    registerKillSessionHandler(session.rpcHandlerManager, lifecycle)

    const codeBuddySession = new CodeBuddySession({
        api,
        client: session,
        path: workingDirectory,
        logPath: logger.getLogPath(),
        sessionId: opts.resumeSessionId ?? null,
        messageQueue: queue,
        onModeChange: () => {},
        permissionMode: opts.permissionMode,
        startedBy
    })
    const launcher = new CodeBuddyRemoteLauncher(codeBuddySession)
    sessionRef.current = codeBuddySession
    launcherRef.current = launcher

    let crashed = false
    try {
        await launcher.launch()
    } catch (error) {
        crashed = true
        lifecycle.markCrash(error)
    } finally {
        if (!crashed) lifecycle.setSessionEndReason('completed')
        await lifecycle.cleanupAndExit()
    }
}

