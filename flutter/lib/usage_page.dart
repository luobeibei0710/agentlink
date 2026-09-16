import 'dart:async';

import 'package:flutter/material.dart';

import 'agentlink_theme.dart';
import 'app_model.dart';
import 'domain.dart';

/// 用量页：按范围展示 token 消耗。
///
/// 分两组展示，因为它们口径不同、不能相加：
///
/// - **本机消耗**：由本 Host 管理期间真实产生的用量。
/// - **历史累计**：导入的历史会话各自的累计量。这些累计值包含 HAPI 之前跑过的
///   部分，混进本机消耗会让那个数字失去意义。
///
/// 数据取自电脑端的 `GET /api/usage/summary`。用量是一次性查询，不参与轮询：
/// 进入页面拉一次，切换范围再拉一次。
class UsagePage extends StatefulWidget {
  const UsagePage(this.model, {super.key});

  final AppModel model;

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  /// 范围取值与电脑端约定：`7d` / `30d` / `all`。
  static const _ranges = <(String, String)>[
    ('7d', '7 天'),
    ('30d', '30 天'),
    ('all', '全部'),
  ];

  static const _agentLabels = <String, String>{
    'codex': 'Codex',
    'codebuddy': 'CodeBuddy',
    'claude': 'Claude',
    'cursor': 'Cursor',
  };

  String _range = '7d';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await widget.model.loadUsage(_range);
    if (mounted) setState(() => _loading = false);
  }

  /// Agent 的内部标识转展示名；未知的按原样显示，避免把信息藏起来。
  String _agentLabel(String key) => _agentLabels[key] ?? key;

  /// 模型键。电脑端对拿不到模型的用量填 `unknown` —— 导入的历史大多如此，
  /// 因为早期的 Codex 转录里没有模型字段。
  String _modelLabel(String key) => key == 'unknown' ? '未标注' : key;

  /// 数据缺失时的占位。
  ///
  /// 「读不到」与「真的没有」必须分开说：此前两者共用一句「这段时间没有用量」，
  /// 用户看到这句话只会以为历史丢了，而真实原因常常是还没连上或请求失败。
  Widget _unavailable() {
    final failure = widget.model.error;
    if (failure == null) {
      return const EmptyState(
        icon: Icons.insights_outlined,
        title: '这段时间没有用量',
        hint: '本机管理的会话与导入的历史都会显示在这里',
      );
    }
    return EmptyState(
      icon: Icons.cloud_off_outlined,
      title: '暂时读不到用量',
      hint: failure,
    );
  }

  @override
  Widget build(BuildContext context) {
    final usage = widget.model.usage;
    return Scaffold(
      appBar: AppBar(
        title: const Text('用量', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AgentLinkSpace.lg,
          AgentLinkSpace.md,
          AgentLinkSpace.lg,
          100,
        ),
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: [
                for (final (value, label) in _ranges)
                  ButtonSegment(value: value, label: Text(label)),
              ],
              selected: {_range},
              onSelectionChanged: (value) {
                setState(() => _range = value.first);
                unawaited(_load());
              },
            ),
          ),
          const SizedBox(height: AgentLinkSpace.xl),
          // 额度属于账户，与所选时间范围无关，因此不放进下面的分组里。用
          // AnimatedBuilder 订阅模型：额度随消息轮询到达，进页面之后才拿到也能
          // 显示出来。
          AnimatedBuilder(
            animation: widget.model,
            builder: (context, _) =>
                _QuotaCard(limits: widget.model.rateLimits),
          ),
          const SizedBox(height: AgentLinkSpace.xl),
          if (_loading && usage == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AgentLinkSpace.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (usage == null || usage.isEmpty) ...[
            _unavailable(),
            const SizedBox(height: AgentLinkSpace.md),
            Center(
              child: OutlinedButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新读取'),
              ),
            ),
          ]
          else ...[
            _GroupHeader(
              title: '本机消耗',
              subtitle: '由本机 HAPI 管理期间产生的用量',
            ),
            const SizedBox(height: AgentLinkSpace.md),
            if (usage.managed.isEmpty)
              const _GroupEmpty(text: '这段时间没有本机消耗')
            else ...[
              _TotalCard(group: usage.managed),
              const SizedBox(height: AgentLinkSpace.xl),
              _BarsSection(
                title: '按 Agent',
                subtitle: 'Codex 与 CodeBuddy 各自的消耗',
                rows: usage.managed.byAgent,
                labelOf: _agentLabel,
                empty: '这段时间没有 Agent 用量',
              ),
              const SizedBox(height: AgentLinkSpace.xl),
              _BarsSection(
                title: '按模型',
                subtitle: '消耗最高的模型排在前面',
                rows: usage.managed.byModel,
                labelOf: _modelLabel,
                empty: '这段时间没有模型用量',
              ),
              const SizedBox(height: AgentLinkSpace.xl),
              _DailySection(rows: usage.managed.daily),
            ],
            if (!usage.imported.isEmpty) ...[
              const SizedBox(height: AgentLinkSpace.xl * 1.5),
              const Divider(color: AgentLinkColors.line, height: 1),
              const SizedBox(height: AgentLinkSpace.xl),
              _GroupHeader(
                title: '历史累计',
                subtitle: '导入的会话各自的总量，含 HAPI 之前的部分',
              ),
              const SizedBox(height: AgentLinkSpace.md),
              _TotalCard(group: usage.imported),
              const SizedBox(height: AgentLinkSpace.xl),
              _BarsSection(
                title: '按 Agent',
                subtitle: '历史会话按 Agent 分组',
                rows: usage.imported.byAgent,
                labelOf: _agentLabel,
                empty: '没有历史用量',
              ),
              const SizedBox(height: AgentLinkSpace.xl),
              _BarsSection(
                title: '按模型',
                subtitle: '历史会话按模型分组',
                rows: usage.imported.byModel,
                labelOf: _modelLabel,
                empty: '没有历史用量',
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 额度卡片：套餐、各时间窗已用比例与重置时间。
///
/// 数据来自 Codex 在消息流里下发的 `rate_limits`。拿不到时不留白 —— 用户打开
/// 这个页面本身就是在找额度，所以要说清楚为什么没有。
class _QuotaCard extends StatelessWidget {
  const _QuotaCard({required this.limits});

  final RateLimits? limits;

  /// 分钟数转成人话。Codex 的窗口是 300（5 小时）、10080（7 天）、43200（30 天）。
  static String _windowLabel(int? minutes) {
    if (minutes == null) return '额度';
    if (minutes % 1440 == 0) return '${minutes ~/ 1440} 天额度';
    if (minutes % 60 == 0) return '${minutes ~/ 60} 小时额度';
    return '$minutes 分钟额度';
  }

  /// 重置时间同时给绝对时刻与剩余时长 —— 只说「还有 3 天」不够，用户往往要
  /// 对上具体是哪天。
  static String _resetLabel(int? resetsAt) {
    if (resetsAt == null) return '';
    final at = DateTime.fromMillisecondsSinceEpoch(resetsAt);
    final clock = '${at.month}月${at.day}日 '
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    final left = at.difference(DateTime.now());
    if (left.isNegative) return '$clock 重置';
    if (left.inHours >= 1) return '$clock 重置（${left.inHours} 小时后）';
    return '$clock 重置（${left.inMinutes} 分钟后）';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = limits;
    if (data == null || data.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AgentLinkSpace.lg),
          child: Text(
            '还没有读到额度信息。额度由 Codex 在会话中下发，打开一个 Codex 会话后'
            '就会显示在这里。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AgentLinkColors.faint,
            ),
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AgentLinkSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '账户额度',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (data.planType != null)
                  Text(
                    data.planType!.toUpperCase(),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: AgentLinkColors.brand,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            if (data.primary != null) ...[
              const SizedBox(height: AgentLinkSpace.lg),
              _window(theme, data.primary!),
            ],
            if (data.secondary != null) ...[
              const SizedBox(height: AgentLinkSpace.md),
              _window(theme, data.secondary!),
            ],
            // 窗口为空说明账户当前没受限。仍要占位，否则整张卡只剩套餐名，
            // 看起来像加载失败。
            if (data.primary == null && data.secondary == null)
              Padding(
                padding: const EdgeInsets.only(top: AgentLinkSpace.md),
                child: Text(
                  data.hasCredits == false ? '当前没有可用额度余额' : '当前额度未受限',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AgentLinkColors.muted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _window(ThemeData theme, RateLimitWindow window) {
    final ratio = (window.usedPercent / 100).clamp(0.0, 1.0);
    // 90% 以上用琥珀色：Codex 通常在接近上限时才开始拒绝请求，这个阈值能让
    // 用户在真正被拦住之前先看到。
    final critical = window.usedPercent >= 90;
    final accent = critical ? AgentLinkColors.amber : AgentLinkColors.brand;
    final reset = _resetLabel(window.resetsAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _windowLabel(window.windowMinutes),
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Text(
              '${window.usedPercent.round()}%',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 6,
            backgroundColor: AgentLinkColors.line,
            valueColor: AlwaysStoppedAnimation<Color>(accent),
          ),
        ),
        if (reset.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              reset,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AgentLinkColors.muted,
              ),
            ),
          ),
      ],
    );
  }
}

/// 分组标题：大标题 + 一句口径说明。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AgentLinkSpace.xs),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AgentLinkColors.muted,
          ),
        ),
      ],
    );
  }
}

/// 某组没有数据时的占位，保持两组的视觉结构一致。
class _GroupEmpty extends StatelessWidget {
  const _GroupEmpty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AgentLinkSpace.lg),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AgentLinkColors.faint),
      ),
    ),
  );
}

/// 合计卡片：主数字是总 token，下面拆出输入/输出/缓存与请求数。
class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.group});

  final UsageGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totals = group.totals;
    // totalTokens 只含输入+输出；缓存读写是输入的一部分，单独列出但不叠加，
    // 否则同一批 token 会被算两次。
    final rows = <(String, String)>[
      ('输入', formatTokenCount(totals.inputTokens)),
      ('输出', formatTokenCount(totals.outputTokens)),
      if (totals.cacheReadTokens > 0)
        ('缓存读取', formatTokenCount(totals.cacheReadTokens)),
      if (totals.cacheCreationTokens > 0)
        ('缓存写入', formatTokenCount(totals.cacheCreationTokens)),
      ('请求', '${totals.requests}'),
      ('会话', '${group.sessions}'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AgentLinkSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '总消耗',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AgentLinkColors.muted,
              ),
            ),
            const SizedBox(height: AgentLinkSpace.xs),
            Text(
              formatTokenCount(totals.totalTokens),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AgentLinkSpace.md),
            Wrap(
              spacing: AgentLinkSpace.lg,
              runSpacing: AgentLinkSpace.sm,
              children: [
                for (final (label, value) in rows)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$label ',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AgentLinkColors.muted,
                        ),
                      ),
                      Text(
                        value,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 一组横向条形：标题 + 若干行，条长按该组的最大值归一化。
class _BarsSection extends StatelessWidget {
  const _BarsSection({
    required this.title,
    required this.subtitle,
    required this.rows,
    required this.labelOf,
    required this.empty,
  });

  final String title;
  final String subtitle;
  final List<UsageBucket> rows;
  final String Function(String key) labelOf;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 归一化基准取整组最大值，避免个别超长条目把其余压成看不见的细线。
    final max = rows.fold<int>(
      0,
      (value, row) => row.totalTokens > value ? row.totalTokens : value,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(title),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AgentLinkColors.muted,
          ),
        ),
        const SizedBox(height: AgentLinkSpace.md),
        if (rows.isEmpty)
          Text(
            empty,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AgentLinkColors.faint,
            ),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AgentLinkSpace.lg,
                vertical: AgentLinkSpace.md,
              ),
              child: Column(
                children: [
                  for (final row in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AgentLinkSpace.sm,
                      ),
                      child: _UsageBar(
                        label: labelOf(row.key),
                        bucket: row,
                        max: max == 0 ? 1 : max,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 单条用量：名称 + 数值 + 按比例的进度条。
class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.label,
    required this.bucket,
    required this.max,
  });

  final String label;
  final UsageBucket bucket;
  final int max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = max == 0 ? 0.0 : (bucket.totalTokens / max).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: AgentLinkSpace.md),
            Text(
              formatTokenCount(bucket.totalTokens),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 6,
            backgroundColor: AgentLinkColors.line,
            valueColor: const AlwaysStoppedAnimation(AgentLinkColors.brand),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${bucket.requests} 次请求 · 未缓存 ${formatTokenCount(bucket.uncachedTokens)}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: AgentLinkColors.muted,
          ),
        ),
      ],
    );
  }
}

/// 每日用量：紧凑柱状，只标注首尾日期，避免手机上标签互相压叠。
class _DailySection extends StatelessWidget {
  const _DailySection({required this.rows});

  final List<UsageBucket> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (rows.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('每日用量'),
          Text(
            '这段时间没有记录',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AgentLinkColors.faint,
            ),
          ),
        ],
      );
    }
    final max = rows.fold<int>(
      0,
      (value, row) => row.totalTokens > value ? row.totalTokens : value,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('每日用量'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AgentLinkSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 96,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final row in rows)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1.5),
                            child: Tooltip(
                              message:
                                  '${row.key}\n${formatTokenCount(row.totalTokens)} · ${row.requests} 次请求',
                              child: Container(
                                height: max == 0
                                    ? 2
                                    : (96 * row.totalTokens / max).clamp(2.0, 96.0),
                                decoration: BoxDecoration(
                                  color: AgentLinkColors.brand,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AgentLinkSpace.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      rows.first.key,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AgentLinkColors.muted,
                      ),
                    ),
                    Text(
                      rows.last.key,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AgentLinkColors.muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
