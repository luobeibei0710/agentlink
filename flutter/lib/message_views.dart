import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'agentlink_theme.dart';
import 'domain.dart';

/// 等宽字体族；Android 与 iOS 都能解析的通用族名。
const String kCodeFontFamily = 'monospace';

/// Markdown 正文渲染。
///
/// 样式对齐 Web 端 `markdown-text.tsx`：标题有层级、引用带左侧色条、
/// 行内代码与代码块用等宽字体并带底色、链接使用品牌色。
class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium?.copyWith(height: 1.55);
    final code = TextStyle(
      fontFamily: kCodeFontFamily,
      fontSize: (body?.fontSize ?? 14) - 1,
      height: 1.5,
      color: AgentLinkColors.ink,
    );
    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        h1: body?.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
        h2: body?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
        h3: body?.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
        h4: body?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
        listBullet: body,
        blockquote: body?.copyWith(color: AgentLinkColors.muted),
        blockquoteDecoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: AgentLinkColors.line, width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        code: code.copyWith(backgroundColor: AgentLinkColors.background),
        codeblockPadding: EdgeInsets.zero,
        codeblockDecoration: const BoxDecoration(),
        tableBorder: const TableBorder.symmetric(
          inside: BorderSide(color: AgentLinkColors.line),
        ),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 6,
        ),
        a: body?.copyWith(
          color: AgentLinkColors.brand,
          decoration: TextDecoration.underline,
        ),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AgentLinkColors.line)),
        ),
      ),
      builders: {'pre': _CodeBlockBuilder()},
    );
  }
}

/// 把 fenced 代码块替换成带语言标签与复制按钮的样式块。
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    if (code.isEmpty) return const SizedBox.shrink();
    return ChatCodeBlock(code: code, language: _languageOf(element));
  }

  /// 从 `pre > code` 的 class 属性中取语言名。
  String _languageOf(md.Element element) {
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is! md.Element) continue;
      final classes = child.attributes['class'];
      if (classes == null) continue;
      final match = RegExp(r'language-([\w+#-]+)').firstMatch(classes);
      if (match != null) return match.group(1)!;
    }
    return '';
  }
}

/// 等宽代码块：语言标签、复制按钮、横向滚动，长代码限高折叠。
///
/// 对应 Web 端 `CodeBlock.tsx` 与 `CodeHeader`，标题栏与复制按钮的排布一致。
class ChatCodeBlock extends StatefulWidget {
  const ChatCodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.title = '',
    this.showLineNumbers = false,
    this.maxHeight = 320,
  });

  final String code;
  final String language;

  /// 标题栏文案；为空时回退到语言名，两者都为空则不显示标题栏。
  final String title;
  final bool showLineNumbers;
  final double maxHeight;

  @override
  State<ChatCodeBlock> createState() => _ChatCodeBlockState();
}

class _ChatCodeBlockState extends State<ChatCodeBlock> {
  bool _expanded = false;

  String get _label => widget.title.isNotEmpty
      ? widget.title
      : widget.language.isNotEmpty
      ? widget.language
      : '';

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制代码')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeStyle = TextStyle(
      fontFamily: kCodeFontFamily,
      fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) - 1.5,
      height: 1.5,
      color: AgentLinkColors.ink,
    );
    final lines = widget.code.split('\n');
    final collapsible = lines.length > 18 || widget.code.length > 1800;

    final body = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: widget.showLineNumbers
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    List<String>.generate(lines.length, (i) => '${i + 1}')
                        .join('\n'),
                    style: codeStyle.copyWith(color: AgentLinkColors.muted),
                  ),
                  const SizedBox(width: 12),
                  Text(widget.code, style: codeStyle),
                ],
              )
            : Text(widget.code, style: codeStyle),
      ),
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: AgentLinkColors.background,
        border: Border.all(color: AgentLinkColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_label.isNotEmpty || collapsible)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AgentLinkColors.line),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AgentLinkColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (collapsible)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      tooltip: _expanded ? '折叠' : '展开',
                      icon: Icon(
                        _expanded ? Icons.unfold_less : Icons.unfold_more,
                        color: AgentLinkColors.muted,
                      ),
                      onPressed: () => setState(() => _expanded = !_expanded),
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    tooltip: '复制',
                    icon: const Icon(
                      Icons.content_copy,
                      color: AgentLinkColors.muted,
                    ),
                    onPressed: _copy,
                  ),
                ],
              ),
            ),
          if (collapsible && !_expanded)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.maxHeight),
              child: body,
            )
          else
            body,
        ],
      ),
    );
  }
}

/// 思考过程面板，样式对齐 ChatGPT：默认只占一行灰色小字，点击才展开。
///
/// 折叠时显示耗时（如「思考了 12 秒」）；耗时无法可靠推算时退回「思考过程」。
/// 展开后是灰色小字正文，不使用彩色容器，避免在对话流里过于抢眼。
class ReasoningPanel extends StatefulWidget {
  const ReasoningPanel(this.text, {super.key, this.durationMs});

  final String text;

  /// 思考耗时；为 null 时不显示时长。
  final int? durationMs;

  @override
  State<ReasoningPanel> createState() => _ReasoningPanelState();
}

class _ReasoningPanelState extends State<ReasoningPanel> {
  bool _expanded = false;

  String get _label {
    final milliseconds = widget.durationMs;
    if (milliseconds == null) return '思考过程';
    final seconds = (milliseconds / 1000).round();
    // 一分钟以内直接说秒数，更贴近 ChatGPT 的措辞。
    return seconds < 60 ? '思考了 $seconds 秒' : '思考了 ${formatDurationLabel(milliseconds)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted =
        theme.textTheme.labelMedium?.copyWith(color: AgentLinkColors.muted) ??
        const TextStyle();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_label, style: muted),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: AgentLinkColors.muted,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: SelectableText(
              widget.text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AgentLinkColors.muted,
                height: 1.6,
              ),
            ),
          ),
      ],
    );
  }
}

/// 工具调用卡片：图标、工具名、参数摘要、执行状态与可展开详情。
///
/// 对应 Web 端 `ToolCard.tsx`。工具结果由相邻的 tool-call-result 消息并入，
/// 因此这张卡片同时负责展示输入与输出。
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.message, this.result});

  final ChatMessage message;

  /// 相邻的同 callId 结果消息；为 null 表示结果尚未返回。
  final ChatMessage? result;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  static const Map<String, IconData> _toolIcons = {
    'read': Icons.description_outlined,
    'write': Icons.edit_outlined,
    'edit': Icons.edit_outlined,
    'bash': Icons.terminal,
    'shell': Icons.terminal,
    'grep': Icons.search,
    'glob': Icons.search,
    'ls': Icons.folder_outlined,
    'webfetch': Icons.public,
    'websearch': Icons.public,
    'todowrite': Icons.checklist,
    'update_plan': Icons.checklist,
    'exit_plan_mode': Icons.flag_outlined,
  };

  IconData get _icon =>
      _toolIcons[widget.message.toolName.toLowerCase()] ?? Icons.build_outlined;

  /// 孤立的结果消息没有工具名，用统一标题兜底。
  String get _title =>
      widget.message.toolName.isNotEmpty ? widget.message.toolName : '工具结果';

  /// 从参数中挑选最能说明这条调用的一句话。
  String get _subtitle {
    final Object? input = widget.message.toolInput;
    if (input is String) return input.replaceAll('\n', ' ').trim();
    final map = input is Map ? input.cast<String, dynamic>() : const {};
    for (final key in const [
      'path',
      'file_path',
      'filePath',
      'command',
      'cmd',
      'pattern',
      'query',
      'url',
      'description',
    ]) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty)
        return value.replaceAll('\n', ' ').trim();
    }
    if (map.isNotEmpty) return jsonEncode(map);
    return '';
  }

  /// 把任意载荷转成可展示文本，结构化内容按两空格缩进展开。
  static String formatPayload(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return '$value';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = widget.result?.toolFailed ?? false;
    final pending = widget.result == null;
    final subtitle = _subtitle;
    final output = formatPayload(widget.result?.toolOutput);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: failed ? AgentLinkColors.amber : AgentLinkColors.line,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_icon, size: 18, color: AgentLinkColors.teal),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFamily: kCodeFontFamily,
                          ),
                        ),
                        if (subtitle.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AgentLinkColors.muted,
                                fontFamily: kCodeFontFamily,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    pending
                        ? Icons.more_horiz
                        : failed
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    size: 18,
                    color: pending
                        ? AgentLinkColors.muted
                        : failed
                        ? AgentLinkColors.amber
                        : AgentLinkColors.teal,
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AgentLinkColors.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1, color: AgentLinkColors.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.message.toolInput != null) ...[
                    _SectionLabel(label: '参数'),
                    ChatCodeBlock(
                      code: formatPayload(widget.message.toolInput),
                      title: 'Input',
                      showLineNumbers: true,
                      maxHeight: 240,
                    ),
                  ],
                  if (output.isNotEmpty) ...[
                    _SectionLabel(
                      label: failed ? '错误输出' : '输出',
                      warning: failed,
                    ),
                    ChatCodeBlock(
                      code: output,
                      title: 'Output',
                      showLineNumbers: true,
                      maxHeight: 240,
                    ),
                  ] else if (pending) ...[
                    _SectionLabel(label: '状态'),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '等待结果…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AgentLinkColors.muted,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.warning = false});

  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: warning ? AgentLinkColors.amber : AgentLinkColors.muted,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// 居中状态行：token 用量、错误、压缩与目标状态等事件。
///
/// 对应 Web 端 `SystemMessage.tsx`。
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.text, this.icon = ''});

  final String text;
  final String icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon.isNotEmpty) ...[
          Text(icon, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AgentLinkColors.muted,
            ),
          ),
        ),
      ],
    ),
  );
}
