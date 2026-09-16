export const ACP_SESSION_UPDATE_TYPES = {
    agentMessageChunk: 'agent_message_chunk',
    agentThoughtChunk: 'agent_thought_chunk',
    toolCall: 'tool_call',
    toolCallUpdate: 'tool_call_update',
    plan: 'plan',
    usageUpdate: 'usage_update',
    sessionInfoUpdate: 'session_info_update',
    // CodeBuddy 用它下发会话级配置（权限档位、模型、思考等级、沙箱）。
    configOptionUpdate: 'config_option_update'
} as const;
