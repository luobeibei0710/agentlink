import React from 'react'
import { convertAgentMessage } from '@/agent/messageConverter'
import type { AgentMessage, PromptContent } from '@/agent/types'
import { logger } from '@/ui/logger'
import { RemoteModeDisplay } from '@/ui/ink/RemoteModeDisplay'
import {
    RemoteLauncherBase,
    type RemoteLauncherDisplayContext,
    type RemoteLauncherExitReason
} from '@/modules/common/remote/RemoteLauncherBase'
import { AcpPermissionHandler } from '@/modules/common/permission/AcpPermissionHandler'
import { registerSessionConfigRpc } from '@/agent/sessionConfigRpc'
import { RPC_METHODS } from '@hapi/protocol/rpcMethods'
import type { PermissionMode } from '@hapi/protocol/types'
import { createCodeBuddyBackend } from './utils/codeBuddyBackend'
import type { CodeBuddySession } from './session'

export class CodeBuddyRemoteLauncher extends RemoteLauncherBase {
    private backend: ReturnType<typeof createCodeBuddyBackend> | null = null
    private permissionHandler: AcpPermissionHandler | null = null
    private abortController = new AbortController()
    /** ACP 会话 id；运行中切换权限模式需要它。 */
    private acpSessionId: string | null = null

    constructor(private readonly session: CodeBuddySession) {
        super(process.env.DEBUG ? session.logPath : undefined)
    }

    async launch(): Promise<RemoteLauncherExitReason> {
        return this.start({ onExit: () => this.handleExitFromUi() })
    }

    async kill(): Promise<void> {
        if (!this.backend) return
        await this.handleAbort()
    }

    protected createDisplay(context: RemoteLauncherDisplayContext): React.ReactElement {
        return React.createElement(RemoteModeDisplay, {
            ...context,
            agentLabel: 'CodeBuddy'
        })
    }

    protected async runMainLoop(): Promise<void> {
        const backend = createCodeBuddyBackend()
        this.backend = backend
        backend.onStderrError((error) => {
            logger.debug('[codebuddy-acp] stderr error', error)
            this.session.sendSessionEvent({ type: 'message', message: error.message })
            this.messageBuffer.addMessage(error.message, 'status')
        })

        await backend.initialize()
        const requestedResumeId = this.session.sessionId
        let acpSessionId: string
        if (requestedResumeId) {
            if (!backend.supportsLoadSession()) {
                throw new Error('This CodeBuddy ACP version does not advertise session history resume')
            }
            acpSessionId = await backend.loadSession({
                sessionId: requestedResumeId,
                cwd: this.session.path,
                mcpServers: []
            })
        } else {
            acpSessionId = await backend.newSession({
                cwd: this.session.path,
                mcpServers: []
            })
        }

        // A native ID is durable only when this concrete ACP process says it can
        // load it later. Older/alternate CodeBuddy builds remain usable for a
        // fresh turn but do not make the HAPI row advertise false resume support.
        if (backend.supportsLoadSession()) {
            this.session.onSessionFound(acpSessionId)
        } else {
            this.session.sessionId = acpSessionId
        }

        this.acpSessionId = acpSessionId
        this.permissionHandler = new AcpPermissionHandler(
            this.session.client,
            backend,
            () => this.session.getPermissionMode() ?? 'default'
        )
        // 恢复的会话可能带着非 default 的档位，先切过去，让第一个 turn 就在
        // 正确的权限下执行。
        await this.applyPermissionMode(this.session.getPermissionMode(), { initial: true })
        // Hub 下发 set-session-config 时通过 ACP 实时切换档位。
        registerSessionConfigRpc({
            rpcHandlerManager: this.session.client.rpcHandlerManager,
            flavor: 'codebuddy',
            // 模型与权限档位走同一条 ACP 通道：CodeBuddy 在 config_option_update
            // 里同时下发 category=model 的选项与当前值，所以这里可以像档位一样
            // 直接接受并应用，而不是把请求丢掉。
            modelMode: 'nullable',
            modelReasoningEffortMode: 'ignore',
            effortMode: 'ignore',
            onApply: async (config) => {
                await this.applyPermissionMode(config.permissionMode)
                await this.applyModel(config.model)
            },
            appliedFallback: () => ({
                permissionMode: this.session.getPermissionMode() ?? 'default'
            })
        })
        // 模型列表取自本会话的 ACP 配置选项，因此只能在这里注册（依赖 acpSessionId）。
        // CodeBuddy 在会话就绪后随即下发 config_option_update，正常情况下第一次
        // 请求就能取到；取不到时如实返回失败，让手机端提示而不是显示空列表。
        this.session.client.rpcHandlerManager.registerHandler(
            RPC_METHODS.ListCodebuddyModels,
            async () => {
                const acpSessionId = this.acpSessionId
                const option = this.backend && acpSessionId
                    ? this.backend.getConfigOptionByCategory(acpSessionId, 'model')
                    : undefined
                if (!option) {
                    return { success: false, error: '会话尚未下发模型列表' }
                }
                return {
                    success: true,
                    currentModelId: option.currentValue ?? null,
                    models: option.options.map((entry) => ({
                        modelId: entry.value,
                        name: entry.name,
                        description: entry.description
                    }))
                }
            }
        )
        this.setupAbortHandlers(this.session.client.rpcHandlerManager, {
            onAbort: () => this.handleAbort(),
            onSwitch: () => this.handleExitFromUi()
        })
        // Resume callers wait for this barrier before reporting success. It is
        // emitted only after initialize + session/load|new and permission RPC
        // wiring have all completed.
        if (!await this.session.client.flushMetadata()) {
            throw new Error('CodeBuddy native session metadata was not acknowledged by Hub')
        }
        this.session.client.emitSessionReady()
        this.session.sendSessionEvent({ type: 'ready' })

        while (!this.shouldExit) {
            const batch = await this.session.queue.waitForMessagesAndGetAsString(this.abortController.signal)
            if (!batch) {
                if (this.abortController.signal.aborted && !this.shouldExit) continue
                break
            }

            this.session.onThinkingChange(true)
            this.messageBuffer.addMessage(batch.message, 'user')
            const prompt: PromptContent[] = [{ type: 'text', text: batch.message }]
            try {
                await backend.prompt(acpSessionId, prompt, (message) => this.handleAgentMessage(message))
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error)
                logger.warn('[codebuddy-acp] prompt failed', { message })
                this.session.sendSessionEvent({
                    type: 'message',
                    message: `CodeBuddy prompt failed: ${message}`
                })
                this.messageBuffer.addMessage(`CodeBuddy prompt failed: ${message}`, 'status')
            } finally {
                this.session.onThinkingChange(false)
                await this.permissionHandler?.cancelAll('Prompt finished')
                if (this.session.queue.size() === 0 && !this.shouldExit) {
                    this.session.sendSessionEvent({ type: 'ready' })
                }
            }
        }
    }

    protected async cleanup(): Promise<void> {
        this.clearAbortHandlers(this.session.client.rpcHandlerManager)
        await this.permissionHandler?.cancelAll('Session ended')
        this.permissionHandler = null
        await this.backend?.disconnect()
        this.backend = null
        this.acpSessionId = null
    }

    private handleAgentMessage(message: AgentMessage): void {
        const converted = convertAgentMessage(message)
        if (converted) this.session.sendAgentMessage(converted)

        switch (message.type) {
            case 'text':
                this.messageBuffer.addMessage(message.text, 'assistant')
                break
            case 'generated_image':
                this.messageBuffer.addMessage(`Generated image: ${message.fileName}`, 'assistant')
                break
            case 'error':
                this.messageBuffer.addMessage(message.message, 'status')
                break
            case 'turn_complete':
                this.messageBuffer.addMessage('Turn complete', 'status')
                break
            case 'usage':
            case 'reasoning':
            case 'tool_call':
            case 'tool_result':
            case 'plan':
                break
            default: {
                const _exhaustive: never = message
                return _exhaustive
            }
        }
    }

    /**
     * 通过 ACP 切换权限档位。
     *
     * CodeBuddy 是用 `session/update` 的 `config_option_update` 下发档位的（而不是
     * `session/new` 的返回值），因此 `AcpSdkBackend.setMode` 找不到 mode 选项而报错。
     * 这里直接发 `session/set_config_option`，configId 固定为 `mode` —— 该 id 与
     * 档位列表都由 CodeBuddy 的 ACP 服务端提供，其他 agent 不走这条路径。
     *
     * @param mode 目标档位
     * @param options.initial 启动路径。ACP 子进程固定以 `--permission-mode default`
     *   启动（见 codeBuddyBackend 的 SAFE_BASE_ARGS），所以这里必须拿 `default`
     *   去比较 —— 否则「恢复一个曾设为 plan 的会话」会因为 session 的目标值与
     *   当前值相同而被误判为无需切换，导致第一个 turn 用了错误的档位。
     */
    private async applyPermissionMode(
        mode: PermissionMode | undefined,
        options: { initial?: boolean } = {}
    ): Promise<void> {
        const backend = this.backend
        const acpSessionId = this.acpSessionId
        if (!backend || !acpSessionId || !mode) return
        const current = options.initial
            ? 'default'
            : (this.session.getPermissionMode() ?? 'default')
        if (mode === current) return
        await backend.setConfigOption(acpSessionId, 'mode', mode)
        this.session.setPermissionMode(mode)
    }

    /**
     * 通过 ACP 切换模型。
     *
     * 与权限档位共用一条通道：CodeBuddy 在 `config_option_update` 里同时下发
     * `category=model` 的选项（含当前值、展示名与计费倍率），所以直接发
     * `session/set_config_option`、configId 固定为 `model` 即可，响应会带回
     * 更新后的完整配置。
     *
     * @param model 目标模型 id。null / 空串表示沿用当前模型 —— ACP 的切换请求
     *   必须带具体值，没有「重置为服务端默认」这种表达。
     */
    private async applyModel(model: string | null | undefined): Promise<void> {
        const backend = this.backend
        const acpSessionId = this.acpSessionId
        if (!backend || !acpSessionId || !model) return
        await backend.setConfigOption(acpSessionId, 'model', model)
        this.session.setModel(model)
    }

    private async handleAbort(): Promise<void> {
        if (this.backend && this.session.sessionId) {
            await this.backend.cancelPrompt(this.session.sessionId)
        }
        await this.permissionHandler?.cancelAll('User aborted')
        this.session.sendSessionEvent({ type: 'message', message: 'Session aborted' })
        this.session.queue.reset()
        this.session.onThinkingChange(false)
        this.abortController.abort()
        this.abortController = new AbortController()
        this.messageBuffer.addMessage('Turn aborted', 'status')
    }

    private async handleExitFromUi(): Promise<void> {
        await this.requestExit('exit', () => this.handleAbort())
    }
}
