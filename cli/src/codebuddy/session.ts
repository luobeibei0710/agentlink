import { ApiClient, ApiSessionClient } from '@/lib'
import type { PermissionMode } from '@hapi/protocol/types'
import { AgentSessionBase } from '@/agent/sessionBase'
import { MessageQueue2 } from '@/utils/MessageQueue2'
import type { CodeBuddyMode } from './types'

/** Remote-only HAPI wrapper for a CodeBuddy ACP session. */
export class CodeBuddySession extends AgentSessionBase<CodeBuddyMode> {
    readonly startedBy: 'runner' | 'terminal'

    constructor(opts: {
        api: ApiClient
        client: ApiSessionClient
        path: string
        logPath: string
        sessionId: string | null
        messageQueue: MessageQueue2<CodeBuddyMode>
        onModeChange: (mode: 'local' | 'remote') => void
        startedBy: 'runner' | 'terminal'
        permissionMode?: PermissionMode
    }) {
        super({
            api: opts.api,
            client: opts.client,
            path: opts.path,
            logPath: opts.logPath,
            sessionId: opts.sessionId,
            messageQueue: opts.messageQueue,
            onModeChange: opts.onModeChange,
            mode: 'remote',
            sessionLabel: 'CodeBuddySession',
            sessionIdLabel: 'CodeBuddy ACP',
            applySessionIdToMetadata: (metadata, sessionId) => ({
                ...metadata,
                codebuddySessionId: sessionId
            }),
            permissionMode: opts.permissionMode ?? 'default'
        })
        this.startedBy = opts.startedBy
    }

    /**
     * 运行中切换权限模式。
     *
     * 基类的 permissionMode 只在构造时赋值。这里开放一个写入口，让 launcher 在
     * 收到 Hub 的 set-session-config 后同步本地状态 —— keepAlive 会把新值上报，
     * 手机端与电脑端 Web 才能显示当前档位。
     */
    setPermissionMode(mode: PermissionMode): void {
        this.permissionMode = mode
    }

    /**
     * 运行中切换模型。
     *
     * 与 setPermissionMode 同理：基类的 model 只在构造时赋值，这里开放写入口，
     * 让 launcher 在收到 Hub 的 set-session-config 后同步本地状态。keepAlive
     * 会把新值上报，手机端与电脑端 Web 才能显示当前模型。
     */
    setModel(model: string | null): void {
        this.model = model
    }

    sendAgentMessage = (message: unknown): void => {
        this.client.sendAgentMessage(message)
    }

    sendSessionEvent = (event: Parameters<ApiSessionClient['sendSessionEvent']>[0]): void => {
        this.client.sendSessionEvent(event)
    }
}

