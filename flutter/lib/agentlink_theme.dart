import 'package:flutter/material.dart';

import 'domain.dart';

abstract final class AgentLinkColors {
  static const background = Color(0xfff6f7fb);
  static const ink = Color(0xff182238);
  static const muted = Color(0xff6d768a);
  /// 已结束等非活跃状态的弱化色，比 [muted] 更浅。
  static const faint = Color(0xffc3c9d6);
  static const line = Color(0xffe5e8f0);
  static const brand = Color(0xff5458dc);
  static const lavender = Color(0xffeeedff);
  static const teal = Color(0xff167c72);
  static const mint = Color(0xffe8f5f0);
  static const amber = Color(0xff96610e);
  static const sand = Color(0xfffff3d8);
}

/// 统一间距，取 4 的倍数，避免各处随手写 12/16/18/20 混用。
abstract final class AgentLinkSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
}

/// 会话状态点。
///
/// 用一个 9px 的圆点传达状态，比圆形头像占位小得多，也让项目列表与会话列表
/// 的状态读出方式保持一致。
class StatusDot extends StatelessWidget {
  const StatusDot(this.status, {super.key, this.size = 9});

  final SessionStatus status;
  final double size;

  /// 状态对应的颜色；列表、项目汇总与对话页共用同一套语义。
  static Color colorOf(SessionStatus status) => switch (status) {
    SessionStatus.pending => AgentLinkColors.amber,
    SessionStatus.running => AgentLinkColors.teal,
    SessionStatus.idle => AgentLinkColors.brand,
    SessionStatus.ended => AgentLinkColors.faint,
  };

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: colorOf(status),
      shape: BoxShape.circle,
    ),
  );
}

ThemeData agentLinkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AgentLinkColors.brand,
    brightness: Brightness.light,
    surface: Colors.white,
  ).copyWith(
    primary: AgentLinkColors.brand,
    onPrimary: Colors.white,
    primaryContainer: AgentLinkColors.lavender,
    onPrimaryContainer: AgentLinkColors.ink,
    secondary: AgentLinkColors.teal,
    tertiary: AgentLinkColors.amber,
    tertiaryContainer: AgentLinkColors.sand,
    onTertiaryContainer: AgentLinkColors.ink,
    onSurface: AgentLinkColors.ink,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AgentLinkColors.background,
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: AgentLinkColors.lavender,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AgentLinkColors.brand,
      foregroundColor: Colors.white,
    ),
    textTheme: Typography.material2021().black.apply(
      bodyColor: AgentLinkColors.ink,
      displayColor: AgentLinkColors.ink,
      fontFamily: 'sans-serif',
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      color: Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: AgentLinkColors.line),
      ),
    ),
    // 弹窗与卡片用同一套白底 + 细边框，避免默认的灰底在页面里显得是另一种材质。
    dialogTheme: const DialogThemeData(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
        side: BorderSide(color: AgentLinkColors.line),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: AgentLinkColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: AgentLinkColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AgentLinkColors.brand,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 52),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
    ),
  );
}

/// 列表卡片的统一外壳：白底、圆角、点击涟漪与一致的横向留白。
///
/// 项目行、会话行、待处理行、设备行都用它，避免同一种卡片在各处写出不同的
/// 内边距和圆角半径。
class ListCard extends StatelessWidget {
  const ListCard({required this.onTap, required this.child, super.key});

  /// 传 null 表示当前不可点，此时不会出现点击涟漪。
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AgentLinkSpace.lg,
          vertical: 14,
        ),
        child: child,
      ),
    ),
  );
}

/// 列表分组标题，统一字重与下方间距。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AgentLinkSpace.sm),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

/// 列表行末尾的箭头，统一尺寸与颜色。
class RowChevron extends StatelessWidget {
  const RowChevron({super.key});

  @override
  Widget build(BuildContext context) => const Icon(
    Icons.chevron_right,
    size: 20,
    color: AgentLinkColors.faint,
  );
}

/// 列表空态：图标 + 一句话 + 一句引导。
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.hint,
    super.key,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AgentLinkSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AgentLinkColors.faint),
            const SizedBox(height: AgentLinkSpace.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AgentLinkSpace.xs),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AgentLinkColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


