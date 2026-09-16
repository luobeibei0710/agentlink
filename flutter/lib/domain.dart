import 'dart:convert';

class HubException implements Exception {
  HubException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    required this.cwd,
    required this.flavor,
    required this.active,
    required this.updatedAt,
    this.pending = 0,
    this.thinking = false,
    this.permissionMode,
    this.model,
  });
  final String id, title, cwd, flavor;
  final bool active;
  final bool thinking;
  final int updatedAt, pending;

  /// 电脑端上报的当前权限档位；为空表示该 Agent 不上报或电脑端版本较旧。
  final String? permissionMode;

  /// 电脑端上报的当前模型 id；为空表示该 Agent 不上报或尚未选择。
  final String? model;

  factory SessionSummary.fromJson(Map<String, dynamic> j) {
    final m = _map(j['metadata']);
    final f = '${m['flavor'] ?? ''}'.toLowerCase();
    return SessionSummary(
      id: '${j['id']}',
      title: '${m['name'] ?? _map(m['summary'])['text'] ?? '未命名会话'}',
      cwd: '${m['path'] ?? '未指定目录'}',
      flavor: f.isNotEmpty
          ? f
          : m['codebuddySessionId'] != null
          ? 'codebuddy'
          : '',
      active: j['active'] == true,
      thinking: j['thinking'] == true,
      updatedAt: _int(j['updatedAt']) ?? 0,
      pending: _int(j['pendingRequestsCount']) ?? 0,
      permissionMode: _string(j['permissionMode']),
      model: _string(j['model']),
    );
  }
}

/// 一个可选的模型。
///
/// Codex 与 CodeBuddy 的模型来源不同（前者走 listCodexModels RPC，后者取自会话的
/// ACP 配置选项），但对用户是同一个问题：这个会话能用哪些模型。两端都归一成这个
/// 类型。
class ModelOption {
  const ModelOption(this.id, this.label, {this.note});

  /// 提交给电脑端的模型 id。
  final String id;

  /// 展示名；服务端没给名字时退回 id。
  final String label;

  /// 服务端附带的补充说明。CodeBuddy 用它标注计费倍率（如 `x0.29 credits`）。
  final String? note;
}

/// 一段用量的合计。对应电脑端的 `UsageSummaryBucket`。
///
/// 电脑端把 token 分成四类，并额外给出两个派生值：
/// `totalTokens`（输入+输出）与 `uncachedTokens`（真正未命中缓存的输入+输出，
/// 缓存收益看这个差值）。
class UsageBucket {
  const UsageBucket({
    required this.key,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheCreationTokens,
    required this.totalTokens,
    required this.uncachedTokens,
    required this.requests,
  });

  /// 分组键：日期、Agent 名或模型 id；总计行的键为空。
  final String key;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;
  final int totalTokens;
  final int uncachedTokens;
  final int requests;

  factory UsageBucket.fromJson(Map<String, dynamic> j) => UsageBucket(
    key: '${j['key'] ?? ''}',
    inputTokens: _int(j['inputTokens']) ?? 0,
    outputTokens: _int(j['outputTokens']) ?? 0,
    cacheReadTokens: _int(j['cacheReadTokens']) ?? 0,
    cacheCreationTokens: _int(j['cacheCreationTokens']) ?? 0,
    totalTokens: _int(j['totalTokens']) ?? 0,
    uncachedTokens: _int(j['uncachedTokens']) ?? 0,
    requests: _int(j['requests']) ?? 0,
  );
}

/// 一组用量：合计，以及按天 / 按 Agent / 按模型的分组。
class UsageGroup {
  const UsageGroup({
    required this.totals,
    required this.sessions,
    required this.daily,
    required this.byAgent,
    required this.byModel,
  });

  /// 组内合计；`sessions` 单独给出，因为它不属于 `UsageBucket`。
  final UsageBucket totals;
  final int sessions;

  /// 按天分组的用量，按键升序（即时间正序）。
  final List<UsageBucket> daily;

  /// 按 Agent 分组的用量，按 token 降序。
  final List<UsageBucket> byAgent;

  /// 按模型分组的用量，按 token 降序。
  final List<UsageBucket> byModel;

  bool get isEmpty =>
      totals.totalTokens == 0 && daily.isEmpty && byAgent.isEmpty;

  /// @param totalsKey 合计字段名（本机是 `totals`，历史是 `importedTotals`）
  /// @param prefix 其余字段的前缀（历史是 `imported`）
  static UsageGroup fromJson(
    Map<String, dynamic> j, {
    required String prefix,
  }) {
    final totals = _map(j[prefix.isEmpty ? 'totals' : '${prefix}Totals']);
    String key(String name) =>
        prefix.isEmpty ? name : '$prefix${name[0].toUpperCase()}${name.substring(1)}';
    return UsageGroup(
      totals: UsageBucket.fromJson(totals),
      sessions: _int(totals['sessions']) ?? 0,
      daily: _bucketList(j[key('daily')]),
      byAgent: _bucketList(j[key('byAgent')]),
      byModel: _bucketList(j[key('byModel')]),
    );
  }

  static List<UsageBucket> _bucketList(Object? raw) => [
    if (raw is List)
      for (final row in raw)
        if (row is Map<String, dynamic>) UsageBucket.fromJson(row),
  ];
}

/// 用量总览，对应电脑端的 `GET /api/usage/summary`。
///
/// 分两组：`managed` 是本 Host 管理期间真实产生的消耗，`imported` 是导入的历史
/// 会话的累计量。**两者口径不同，不能相加** —— 历史会话的累计值包含 HAPI 之前
/// 跑过的部分，混在一起会让"本机消耗"失去意义，所以界面必须分开展示。
class UsageSummary {
  const UsageSummary({required this.managed, required this.imported});

  final UsageGroup managed;
  final UsageGroup imported;

  bool get isEmpty => managed.isEmpty && imported.isEmpty;

  factory UsageSummary.fromJson(Map<String, dynamic> j) => UsageSummary(
    managed: UsageGroup.fromJson(j, prefix: ''),
    imported: UsageGroup.fromJson(j, prefix: 'imported'),
  );
}

/// 一个额度时间窗：已用百分比、窗口长度与下次重置时间。
///
/// Codex 只在账户真正受限时才会填 `primary` / `secondary`，平时是 null，因此
/// 整块可能只有套餐名。
class RateLimitWindow {
  const RateLimitWindow({required this.usedPercent, this.windowMinutes, this.resetsAt});

  /// 已用百分比（0–100）。
  final double usedPercent;

  /// 窗口长度（分钟）：300 约 5 小时、10080 是 7 天、43200 是 30 天。
  final int? windowMinutes;

  /// 下次重置时间（毫秒时间戳，已从秒归一）。
  final int? resetsAt;

  static RateLimitWindow? fromJson(Object? raw) {
    final j = _map(raw);
    final used = j['usedPercent'] ?? j['used_percent'];
    if (used is! num) return null;
    final resets = _int(j['resetsAt'] ?? j['resets_at']);
    return RateLimitWindow(
      usedPercent: used.toDouble(),
      windowMinutes: _int(j['windowMinutes'] ?? j['window_minutes']),
      // Codex 给秒、其余接口给毫秒；按量级判断，否则会显示成 1970 年。
      resetsAt: resets == null
          ? null
          : (resets < 100000000000 ? resets * 1000 : resets),
    );
  }
}

/// 账户额度快照，对应 Codex `token_count` 上的 `rate_limits`。
///
/// 额度跟账户走而不是跟会话走，所以全局只保留最新的一份；[seenAt] 用于判断
/// 新旧。
class RateLimits {
  const RateLimits({
    required this.seenAt,
    this.planType,
    this.primary,
    this.secondary,
    this.hasCredits,
  });

  /// 这份快照的到达时间。
  final int seenAt;

  /// 套餐标识，如 `pro` / `prolite` / `plus` / `free`。
  final String? planType;
  final RateLimitWindow? primary;
  final RateLimitWindow? secondary;

  /// 是否还有额外额度余额。为 false 且窗口已用满时，就是完全受限状态。
  final bool? hasCredits;

  bool get isEmpty =>
      primary == null && secondary == null && planType == null;

  static RateLimits? fromJson(Object? raw, int seenAt) {
    final j = _map(raw);
    if (j.isEmpty) return null;
    final primary = RateLimitWindow.fromJson(j['primary']);
    final secondary = RateLimitWindow.fromJson(j['secondary']);
    final plan = _string(j['planType'] ?? j['plan_type']);
    final credits = _map(j['credits']);
    final creditsFlag =
        j['hasCredits'] ??
        j['has_credits'] ??
        credits['hasCredits'] ??
        credits['has_credits'];
    final hasCredits = creditsFlag is bool ? creditsFlag : null;
    if (primary == null &&
        secondary == null &&
        plan == null &&
        hasCredits == null)
      return null;
    return RateLimits(
      seenAt: seenAt,
      planType: plan,
      primary: primary,
      secondary: secondary,
      hasCredits: hasCredits,
    );
  }
}

/// 消息在对话中的展示形态，决定客户端选用哪种渲染组件。
///
/// 分类与 Web 端（`web/src/chat/reducerTimeline.ts` 的 `ChatBlock`）保持一致，
/// 使手机与电脑两端可以用同样的方式呈现同一份历史。
enum MessageView {
  /// 用户输入的气泡。
  user,

  /// 助手文本，按 Markdown 渲染。
  agentText,

  /// 思考过程，默认折叠展示。
  reasoning,

  /// 工具调用卡片；相邻的同 [ChatMessage.callId] 结果会并入这张卡片。
  toolCall,

  /// 工具结果，渲染时并入相邻的同 callId 调用卡片。
  toolResult,

  /// 居中状态行，例如 token 用量、错误、压缩与目标状态。
  status,

  /// 协议内部事件，不参与展示。
  hidden,
}

/// [ChatMessage._decode] 的解析结果，供构造消息时一次性取出所有展示字段。
typedef _Parsed = ({
  MessageView view,
  String text,
  String toolName,
  Object? toolInput,
  Object? toolOutput,
  bool toolFailed,
  String statusIcon,
});

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.localId,
    required this.role,
    required this.view,
    required this.text,
    required this.createdAt,
    this.pending = false,
    this.seq,
    this.invokedAt,
    this.hasInvokedAt = false,
    this.streamId,
    this.callId,
    this.toolName = '',
    this.toolInput,
    this.toolOutput,
    this.toolFailed = false,
    this.statusIcon = '',
    this.rateLimits,
  });
  final String id, localId, role;

  /// 该消息应使用的渲染组件。
  final MessageView view;

  /// 文本正文；用户消息与助手文本有效。
  final String text;
  final int createdAt;
  final bool pending;
  final int? seq, invokedAt;
  final bool hasInvokedAt;
  bool get queued => hasInvokedAt && invokedAt == null;
  final String? streamId, callId;

  /// 工具名，[view] 为 [MessageView.toolCall] 时有效。
  final String toolName;

  /// 工具参数原文，保留结构以便卡片展示与复制。
  final Object? toolInput;

  /// 工具输出原文，由相邻的 tool-call-result 消息提供。
  final Object? toolOutput;

  /// 工具是否执行失败。
  final bool toolFailed;

  /// 状态行前缀图标（如 `◷`、`⚠️`、`📦`）。
  final String statusIcon;

  /// 该消息携带的账户额度快照；只有 Codex 的 `token_count` 会带。
  final RateLimits? rateLimits;

  /// 是否为工具相关消息（调用卡片或结果）。
  bool get tool =>
      view == MessageView.toolCall || view == MessageView.toolResult;

  factory ChatMessage.fromJson(Map<String, dynamic> row) {
    final envelope = _map(row['content']);
    final nested = _map(envelope['content']);
    final role = '${envelope['role'] ?? row['role'] ?? 'agent'}';
    final payload = nested.isNotEmpty ? nested : envelope;
    final parsed = _decode(payload, role);
    final data = _map(payload['data']);
    return ChatMessage(
      id: '${row['id'] ?? row['localId'] ?? ''}',
      localId: '${row['localId'] ?? ''}',
      role: role,
      view: parsed.view,
      text: parsed.text,
      createdAt: _int(row['createdAt']) ?? 0,
      seq: _int(row['seq']),
      invokedAt: _int(row['invokedAt']),
      hasInvokedAt: row.containsKey('invokedAt'),
      streamId: _string(data['id']) ?? _string(data['streamId']),
      callId: _string(data['callId']),
      toolName: parsed.toolName,
      toolInput: parsed.toolInput,
      toolOutput: parsed.toolOutput,
      toolFailed: parsed.toolFailed,
      statusIcon: parsed.statusIcon,
      // 额度搭在 Codex 的 token_count 上一起下发，这里顺手取出来；不是额度消息
      // 时解析成 null。
      rateLimits: RateLimits.fromJson(
        data['rateLimits'],
        _int(row['createdAt']) ?? 0,
      ),
    );
  }

  /// 构造解析结果，未提供的字段使用中性默认值。
  static _Parsed _parsed(
    MessageView view, {
    String text = '',
    String toolName = '',
    Object? toolInput,
    Object? toolOutput,
    bool toolFailed = false,
    String statusIcon = '',
  }) => (
    view: view,
    text: text,
    toolName: toolName,
    toolInput: toolInput,
    toolOutput: toolOutput,
    toolFailed: toolFailed,
    statusIcon: statusIcon,
  );

  static const _Parsed _hidden = (
    view: MessageView.hidden,
    text: '',
    toolName: '',
    toolInput: null,
    toolOutput: null,
    toolFailed: false,
    statusIcon: '',
  );

  static _Parsed _decode(Map<String, dynamic> p, String role) {
    if (p.isEmpty) return _hidden;
    final type = _string(p['type']) ?? '';
    if (role == 'user') {
      final text = _text(p['text'] ?? p['message'] ?? p['content']);
      return text.isEmpty ? _hidden : _parsed(MessageView.user, text: text);
    }
    final d = _map(p['data']);
    if (type == 'codex') return _decodeAgentPayload(d);
    if (type == 'output') return _decodeOutputPayload(d);
    if (type == 'event') {
      final text = _text(d['message'] ?? d['summary']);
      return text.isEmpty
          ? _hidden
          : _parsed(MessageView.status, text: text, statusIcon: '•');
    }
    final text = _text(p['text'] ?? p['message'] ?? p);
    return text.isEmpty
        ? _hidden
        : _parsed(MessageView.agentText, text: text);
  }

  /// 解析 `content.type == 'codex'`（[AGENT_MESSAGE_PAYLOAD_TYPE]）的载荷。
  ///
  /// 各分支与 Web 端 `normalizeAgent.ts` 的 codex 分支逐一对应，状态行文案
  /// 沿用 `presentation.ts`，保证两端看到同样的描述。
  static _Parsed _decodeAgentPayload(Map<String, dynamic> d) {
    switch (_string(d['type']) ?? '') {
      case 'message':
        final text = _text(d['message'] ?? d['text']);
        return text.isEmpty ? _hidden : _parsed(MessageView.agentText, text: text);
      case 'reasoning':
        final text = _text(d['message'] ?? d['text']);
        return text.isEmpty
            ? _hidden
            : _parsed(MessageView.reasoning, text: text);
      case 'error':
        final text = _text(d['error'] ?? d['message']);
        return text.isEmpty
            ? _hidden
            : _parsed(MessageView.status, text: text, statusIcon: '⚠️');
      case 'tool-call':
        final name =
            _string(d['name']) ??
            _string(d['tool']) ??
            _string(d['callId']) ??
            '未知工具';
        return _parsed(
          MessageView.toolCall,
          text: name,
          toolName: name,
          toolInput: d.containsKey('input') ? d['input'] : d['arguments'],
        );
      case 'tool-call-result':
        return _parsed(
          MessageView.toolResult,
          toolOutput: d.containsKey('output') ? d['output'] : d['result'],
          toolFailed: _toolResultFailed(d),
        );
      case 'token_count':
        return _parsed(
          MessageView.status,
          text: formatTokenCountLabel(d),
          statusIcon: '◷',
        );
      case 'plan':
      case 'plan_update':
        return _parsed(
          MessageView.toolCall,
          text: 'update_plan',
          toolName: 'update_plan',
          toolInput: d,
        );
      case 'exit_plan_mode':
        final text = _text(d['message'] ?? d['plan']);
        return _parsed(
          MessageView.toolCall,
          text: 'exit_plan_mode',
          toolName: 'exit_plan_mode',
          toolInput: text.isEmpty ? d : text,
        );
      case 'ask_user_question':
      case 'request_user_input':
        final text = _text(d['questions'] ?? d['message']);
        return text.isEmpty
            ? _hidden
            : _parsed(MessageView.status, text: text, statusIcon: '❓');
      case 'compact-summary':
      case 'context_compacted':
        return _parsed(
          MessageView.status,
          text: 'Context compacted',
          statusIcon: '📦',
        );
      case 'thread_goal_updated':
        return _parsed(
          MessageView.status,
          text: formatThreadGoalLabel(d),
          statusIcon: '🎯',
        );
      case 'thread_goal_cleared':
        return _parsed(MessageView.status, text: 'Goal cleared');
      case 'turn_duration':
        final ms = _int(d['durationMs'] ?? d['duration_ms']) ?? 0;
        return _parsed(
          MessageView.status,
          text: 'Turn: ${formatDurationLabel(ms)}',
          statusIcon: '⏱️',
        );
      default:
        // 子代理 trace、生命周期与未知协议事件不是对话正文。
        return _hidden;
    }
  }

  /// 解析 `content.type == 'output'`（Claude / CodeBuddy 风格）的载荷。
  static _Parsed _decodeOutputPayload(Map<String, dynamic> d) {
    final blocks = _map(d['message'])['content'];
    if (blocks is List) {
      final text = blocks
          .whereType<Map>()
          .map((b) => _text(b['text'] ?? b['content']))
          .where((v) => v.isNotEmpty)
          .join('\n');
      if (text.isNotEmpty)
        return blocks.any((b) => b['type'] != 'text')
            ? _parsed(MessageView.toolCall, text: text, toolName: 'tool')
            : _parsed(MessageView.agentText, text: text);
    }
    final text = _text(d['content'] ?? d['message'] ?? d);
    if (text.isEmpty) return _hidden;
    final kind = _string(d['type']) ?? '';
    return kind == 'assistant' || kind == 'user'
        ? _parsed(MessageView.agentText, text: text)
        : _parsed(MessageView.status, text: text, statusIcon: '•');
  }

  /// 工具结果是否失败：优先看显式状态字段。
  static bool _toolResultFailed(Map<String, dynamic> d) {
    if (d['is_error'] == true || d['isError'] == true) return true;
    final status = _string(d['status']);
    return status == 'error' || status == 'failed';
  }
}

/// 一条待渲染的对话项：普通消息，或已配对的工具调用。
class ChatEntry {
  const ChatEntry(this.message, {this.result, this.reasoningDurationMs});

  final ChatMessage message;

  /// 与 [message] 配对的结果消息，仅工具调用可能非空。
  final ChatMessage? result;

  /// 思考耗时；仅思考面板使用，无法可靠推算时为 null。
  final int? reasoningDurationMs;
}

/// 思考耗时的合理区间：低于一秒无意义，超过十分钟多半是用户中途离开。
const int _kMinReasoningMs = 1000;
const int _kMaxReasoningMs = 10 * 60 * 1000;

/// 把消息列表规整成渲染项：
///
/// - `tool-call-result` 并入相邻的同 callId 调用卡片；
/// - 连续的思考片段合并成一个思考块，并按其后继消息的时间差推算耗时。
///
/// 服务端按事件顺序写入，因此按相邻关系配对即可覆盖绝大多数情况；无法配对
/// 的结果单独成项，避免内容丢失。
///
/// @param messages 按时间正序排列的消息
/// @returns 供列表直接渲染的对话项
List<ChatEntry> buildChatEntries(List<ChatMessage> messages) {
  final entries = <ChatEntry>[];
  for (var index = 0; index < messages.length; index += 1) {
    final message = messages[index];
    if (message.view == MessageView.hidden) continue;

    if (message.view == MessageView.reasoning) {
      final parts = <String>[message.text];
      var last = index;
      while (last + 1 < messages.length &&
          messages[last + 1].view == MessageView.reasoning) {
        last += 1;
        parts.add(messages[last].text);
      }
      index = last;
      final next = last + 1 < messages.length ? messages[last + 1] : null;
      entries.add(
        ChatEntry(
          ChatMessage(
            id: message.id,
            localId: message.localId,
            role: message.role,
            view: MessageView.reasoning,
            text: parts.where((part) => part.isNotEmpty).join('\n\n'),
            createdAt: message.createdAt,
            seq: message.seq,
          ),
          reasoningDurationMs: next == null
              ? null
              : _reasoningDuration(message.createdAt, next.createdAt),
        ),
      );
      continue;
    }

    if (message.view == MessageView.toolResult) {
      final last = entries.isEmpty ? null : entries.last;
      final call = last?.message;
      final idsMatch = call?.callId == null ||
          message.callId == null ||
          call?.callId == message.callId;
      if (call != null &&
          call.view == MessageView.toolCall &&
          last?.result == null &&
          idsMatch) {
        entries[entries.length - 1] = ChatEntry(call, result: message);
        continue;
      }
      entries.add(ChatEntry(message));
      continue;
    }

    entries.add(ChatEntry(message));
  }
  return entries;
}

/// 用后继消息的时间戳推算思考耗时；超出合理区间视为不可用。
int? _reasoningDuration(int startedAt, int endedAt) {
  final elapsed = endedAt - startedAt;
  if (elapsed < _kMinReasoningMs || elapsed > _kMaxReasoningMs) return null;
  return elapsed;
}

/// 按 Web 端 `presentation.ts` 的规则压缩 token 数量。
String formatTokenCount(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 10000) return '${(value / 1000).toStringAsFixed(1)}k';
  if (value >= 1000) return '${(value / 1000).round()}k';
  return '$value';
}

/// 生成 `◷ Context 12k / 200k (6%) · out 1k · cached 3k` 形式的状态行文案。
///
/// 「Context」取**本轮**请求的输入量（`info.last`）：它才是此刻真实占用的规模，
/// 除以窗口得到的占比才有参考价值。此前这里取了会话累计值（`info.total`），而
/// 累计输入是会话至今所有请求的总和，会远超窗口 —— 实测出现 69.8M / 258.4k 得出
/// `27027%` 的荒谬结果。`out` / `cached` / `reasoning` 表达的是这个会话至今的
/// 消耗，仍取累计值，两者口径不同但各自成立。
String formatTokenCountLabel(Map<String, dynamic> d) {
  final info = _map(d['info']);
  final total = _map(info['total']).isNotEmpty ? _map(info['total']) : info;
  if (total.isEmpty) return 'Context updated';
  // 早期载荷没有 `last`，此时退回累计值：显示会退化成改动前的样子，但不至于
  // 丢掉整行信息。
  final last = _map(info['last']);
  final input =
      _int(last['inputTokens'] ?? last['input_tokens']) ??
      _int(total['inputTokens'] ?? total['input_tokens']);
  final output = _int(total['outputTokens'] ?? total['output_tokens']);
  final cached = _int(
    total['cachedInputTokens'] ??
        total['cacheReadInputTokens'] ??
        total['cache_read_input_tokens'],
  );
  final reasoning = _int(
    total['reasoningOutputTokens'] ?? total['reasoning_output_tokens'],
  );
  final window = _int(info['modelContextWindow'] ?? info['model_context_window']);

  final parts = <String>[];
  if (input != null && window != null && window > 0) {
    final pct = ((input / window) * 100).round();
    parts.add(
      'Context ${formatTokenCount(input)} / ${formatTokenCount(window)} ($pct%)',
    );
  } else if (input != null) {
    parts.add('Context ${formatTokenCount(input)}');
  } else {
    parts.add('Context updated');
  }
  if (output != null) parts.add('out ${formatTokenCount(output)}');
  if (cached != null && cached > 0)
    parts.add('cached ${formatTokenCount(cached)}');
  if (reasoning != null && reasoning > 0)
    parts.add('reasoning ${formatTokenCount(reasoning)}');
  return parts.join(' · ');
}

/// 生成 `Goal active · 1.2k / 50k` 形式的目标状态文案。
String formatThreadGoalLabel(Map<String, dynamic> d) {
  final goal = _map(d['goal']);
  if (goal.isEmpty) return 'Goal updated';
  final status = _string(goal['status']) ?? 'updated';
  final label = switch (status) {
    'budgetLimited' => 'limited by budget',
    'usageLimited' => 'limited by usage',
    _ => status,
  };
  final parts = <String>['Goal $label'];
  final used = _int(goal['tokensUsed'] ?? goal['tokens_used']);
  final budget = _int(goal['tokenBudget'] ?? goal['token_budget']);
  if (used != null && budget != null)
    parts.add('${formatTokenCount(used)} / ${formatTokenCount(budget)}');
  return parts.join(' · ');
}

/// 会话在列表里的状态，决定状态点的颜色与文案。
enum SessionStatus {
  /// 有等待用户确认的请求，优先级最高。
  pending('等待处理'),
  /// Agent 正在执行。
  running('执行中'),
  /// 进程在线但空闲，可以直接继续输入。
  idle('在线'),
  /// 会话已结束，需要恢复才能继续。
  ended('已结束');

  const SessionStatus(this.label);

  final String label;

  /// 从会话摘要推导状态；有请求待确认时优先于执行中。
  static SessionStatus of(SessionSummary session) {
    if (session.pending > 0) return SessionStatus.pending;
    if (!session.active) return SessionStatus.ended;
    return session.thinking ? SessionStatus.running : SessionStatus.idle;
  }
}

/// 生成列表用的相对时间文案：`刚刚` / `12 分钟前` / `昨天` / `9 月 10 日`。
///
/// @param timestampMs 毫秒时间戳
/// @param nowMs 当前时间，便于测试注入
String formatRelativeTime(int timestampMs, {int? nowMs}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final elapsed = now - timestampMs;
  if (elapsed < 60000) return '刚刚';
  final minutes = elapsed ~/ 60000;
  if (minutes < 60) return '$minutes 分钟前';
  final hours = minutes ~/ 60;
  if (hours < 24) return '$hours 小时前';
  final days = hours ~/ 24;
  if (days == 1) return '昨天';
  if (days < 7) return '$days 天前';
  final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  return '${date.month} 月 ${date.day} 日';
}

/// 一个可选的权限模式：提交给电脑端的机器值、给用户看的名称，以及一句话说明。
class PermissionModeOption {
  const PermissionModeOption(
    this.mode,
    this.label, {
    this.description,
    this.warning = false,
  });

  final String mode;
  final String label;

  /// 该档位的行为说明，展示在名称下方帮助选择。
  final String? description;

  /// 会跳过权限询问的模式，界面上需要用警示色标出。
  final bool warning;
}

/// 各 Agent 支持的权限模式，与电脑端 `shared/src/modes.ts` 保持一致。
///
/// 只列出手机端会遇到的类型；取值必须与电脑端 Schema 完全一致，否则设置会被拒绝。
const Map<String, List<PermissionModeOption>> _permissionModesByFlavor = {
  'codex': [
    PermissionModeOption(
      'default',
      '默认（每次确认）',
      description: '每次操作前都要你确认',
    ),
    PermissionModeOption('read-only', '只读', description: '只能读取，不能修改文件或执行命令'),
    PermissionModeOption(
      'safe-yolo',
      '安全全自动',
      description: '安全操作自动执行，有风险的操作仍会询问',
    ),
    PermissionModeOption(
      'yolo',
      '全自动',
      description: '不再询问，直接执行',
      warning: true,
    ),
  ],
  // CodeBuddy 的 8 档与电脑端完全一致，取自其 ACP 服务端下发的 configOptions，
  // 并且支持在会话运行中实时切换。
  'codebuddy': [
    PermissionModeOption(
      'default',
      '默认（每次询问）',
      description: '某个工具首次被使用时询问你',
    ),
    PermissionModeOption(
      'acceptEdits',
      '自动接受编辑',
      description: '文件编辑不再询问，其他操作仍需确认',
    ),
    PermissionModeOption('plan', '计划模式', description: '只分析，不修改文件也不执行命令'),
    PermissionModeOption(
      'auto',
      '自动',
      description: 'AI 判定：安全的自动放行，有风险的拒绝',
    ),
    PermissionModeOption(
      'dontAsk',
      '不询问',
      description: '安全操作放行，其余直接拒绝',
    ),
    PermissionModeOption(
      'bypassPermissions',
      '跳过权限检查',
      description: '不再询问任何操作',
      warning: true,
    ),
    PermissionModeOption(
      'fullAccess',
      '完全访问',
      description: '跳过全部检查，包括危险命令',
      warning: true,
    ),
    PermissionModeOption('delegate', '由父会话管理', description: '权限交给父会话决定'),
  ],
  'claude': [
    PermissionModeOption('default', '默认（每次确认）'),
    PermissionModeOption('acceptEdits', '自动接受编辑'),
    PermissionModeOption('auto', '自动'),
    PermissionModeOption('plan', '计划模式'),
    PermissionModeOption('bypassPermissions', '全自动', warning: true),
  ],
  'cursor': [
    PermissionModeOption('default', '默认（每次确认）'),
    PermissionModeOption('plan', '计划模式'),
    PermissionModeOption('ask', '每次询问'),
    PermissionModeOption('autoReview', '自动审查'),
    PermissionModeOption('yolo', '全自动', warning: true),
  ],
  'copilot': [
    PermissionModeOption('default', '默认（每次确认）'),
    PermissionModeOption('read-only', '只读'),
    PermissionModeOption('safe-yolo', '安全全自动'),
    PermissionModeOption('yolo', '全自动', warning: true),
  ],
};

/// 返回某个 Agent 可选的权限模式。
///
/// 未知类型回退到 Claude 的模式集合，与电脑端 `getPermissionModesForFlavor`
/// 的兜底行为一致；返回空列表表示该类型不支持切换权限模式。
///
/// @param flavor Agent 类型（如 `codex`、`codebuddy`）
/// @returns 可选的权限模式，首个为默认项
List<PermissionModeOption> permissionModesForFlavor(String flavor) {
  final normalized = flavor.trim().toLowerCase();
  if (normalized.isEmpty) return const [];
  // 明确不支持切换的类型：电脑端返回空集合。
  if (normalized == 'pi' || normalized == 'dsh') return const [];
  return _permissionModesByFlavor[normalized] ??
      _permissionModesByFlavor['claude']!;
}

/// 生成 `2m 5s` 形式的耗时文案。
String formatDurationLabel(int milliseconds) {
  final totalSeconds = (milliseconds / 1000).round();
  if (totalSeconds < 60) return '${totalSeconds}s';
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final parts = <String>[];
  if (hours > 0) parts.add('${hours}h');
  if (minutes > 0) parts.add('${minutes}m');
  if (seconds > 0) parts.add('${seconds}s');
  return parts.isEmpty ? '0s' : parts.join(' ');
}

class MessagePage {
  const MessagePage({
    required this.messages,
    required this.hasMore,
    this.beforeSeq,
    this.beforeAt,
    this.afterSeq,
    this.afterAt,
    this.snapshotHeadSeq,
    this.snapshotHeadAt,
    this.epoch,
    this.reset = false,
    this.direction,
  });
  final List<ChatMessage> messages;
  final bool hasMore, reset;
  final int? beforeSeq,
      beforeAt,
      afterSeq,
      afterAt,
      snapshotHeadSeq,
      snapshotHeadAt,
      epoch;
  final String? direction;
}

class PendingRequest {
  const PendingRequest({
    required this.id,
    this.sessionId = '',
    required this.tool,
    required this.kind,
    this.args = const {},
  });
  final String id, sessionId, tool, kind;
  final Map<String, dynamic> args;
  bool get needsAnswer => kind == 'input';
  factory PendingRequest.fromEntry(
    String sessionId,
    String id,
    Map<String, dynamic> entry,
  ) {
    final tool = '${entry['tool'] ?? '需要确认'}';
    return PendingRequest(
      id: id,
      sessionId: sessionId,
      tool: tool,
      kind:
          (tool == 'AskUserQuestion' ||
              tool == 'ask_user_question' ||
              tool == 'CursorAskQuestion' ||
              tool == 'request_user_input')
          ? 'input'
          : 'permission',
      args: _map(entry['arguments']),
    );
  }
}

class Machine {
  const Machine({required this.id, required this.name, required this.active});
  final String id, name;
  final bool active;
  factory Machine.fromJson(Map<String, dynamic> j) {
    final m = _map(j['metadata']);
    return Machine(
      id: '${j['id']}',
      name: '${m['displayName'] ?? m['host'] ?? j['id']}',
      active: j['active'] == true,
    );
  }
}

class AgentAvailability {
  const AgentAvailability({
    required this.agent,
    required this.available,
    this.reason,
  });
  final String agent;
  final bool available;
  final String? reason;
  factory AgentAvailability.fromJson(Map<String, dynamic> j) =>
      AgentAvailability(
        agent: '${j['agent']}',
        available: j['available'] == true,
        reason: _string(j['reason']),
      );
}

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const {};
int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v');
String? _string(Object? v) => v is String ? v : null;
String _text(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is List) return v.map(_text).where((x) => x.isNotEmpty).join('\n');
  try {
    return jsonEncode(v);
  } catch (_) {
    return '$v';
  }
}
