import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'agentlink_theme.dart';
import 'app_model.dart';
import 'connection_policy.dart';
import 'domain.dart';
import 'input_answers.dart';
import 'message_views.dart';
import 'qr_scanner.dart';
import 'device_page.dart';
import 'trusted_devices.dart';
import 'usage_page.dart';

/// 对话气泡的最大宽度；手机竖屏不会触及，宽屏与桌面窗口下限制阅读行宽。
const double _kMessageMaxWidth = 720;

/// 输入区主按钮的形态，随会话状态切换。
enum ChatComposerAction {
  /// 正在执行：只能停止。
  stop,

  /// 可以发送消息；会话不在线时发送会自动先恢复。
  send,
}

/// 依据会话状态决定输入区主按钮的形态。
///
/// 只有「执行中」需要换成停止键。历史会话离线时不再要求用户先点一次「继续」：
/// 发送本身会先恢复会话再投递，因此这里不需要第二种形态。
///
/// @param thinking 会话是否正在执行
/// @returns 主按钮应当呈现的形态
ChatComposerAction resolveComposerAction({required bool thinking}) {
  if (thinking) return ChatComposerAction.stop;
  return ChatComposerAction.send;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final model = AppModel();
  runApp(AgentLink(model: model));
  unawaited(model.restore());
}

class AgentLink extends StatefulWidget {
  const AgentLink({super.key, required this.model, this.receiveLinks = true});
  final AppModel model;
  final bool receiveLinks;
  @override
  State<AgentLink> createState() => _AgentLinkState();
}

class _AgentLinkState extends State<AgentLink> {
  static const channel = MethodChannel('app.agentlink.companion/links');
  final navigator = GlobalKey<NavigatorState>();
  bool showingLink = false;
  String? queuedLink;
  String? activeLink;
  @override
  void initState() {
    super.initState();
    if (widget.receiveLinks) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'link' && call.arguments is String) {
          await _link(call.arguments as String);
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final value = await channel.invokeMethod<String>('initialLink');
          if (value != null) await _link(value);
        } on MissingPluginException {
          /* Unit tests and non-Android hosts. */
        }
      });
    }
  }

  Future<void> _link(String value) async {
    PairingTarget target;
    try {
      target = PairingTarget.parseLink(value);
    } on HubException {
      return;
    }
    if (!mounted) return;
    if (showingLink) {
      if (value != activeLink) queuedLink = value;
      return;
    }
    final context = navigator.currentContext;
    if (context == null) return;
    showingLink = true;
    activeLink = value;
    try {
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('连接电脑'),
          content: Text(
            '连接到 ${target.uri.origin}？${target.isLan ? '\n这是局域网 HTTP 连接。' : ''}${widget.model.paired ? '\n这将切换当前连接。' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('连接'),
            ),
          ],
        ),
      );
      if (yes == true && mounted) {
        try {
          await widget.model.pairLink(value, allowLanHttp: target.isLan);
        } catch (_) {
          /* Model displays the error. */
        }
      }
    } finally {
      showingLink = false;
      activeLink = null;
      final next = queuedLink;
      queuedLink = null;
      if (next != null && mounted) unawaited(_link(next));
    }
  }

  @override
  void dispose() {
    if (widget.receiveLinks) channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    title: 'AgentLink',
    debugShowCheckedModeBanner: false,
    theme: agentLinkTheme(),
    home: AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) => widget.model.paired
          ? Home(widget.model)
          : DevicePage(
              model: widget.model,
              isRoot: true,
              onManual: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => Pairing(widget.model))),
            ),
    ),
  );
}

class Pairing extends StatefulWidget {
  const Pairing(this.model, {super.key});
  final AppModel model;
  @override
  State<Pairing> createState() => _PairingState();
}

class _PairingState extends State<Pairing> {
  final hub = TextEditingController(),
      token = TextEditingController(),
      link = TextEditingController();
  bool useLink = false;
  String? localError;
  @override
  void dispose() {
    hub.dispose();
    token.dispose();
    link.dispose();
    super.dispose();
  }

  Future<void> go({bool requireConfirmation = false}) async {
    setState(() => localError = null);
    try {
      late final PairingTarget target;
      late final String pairingCode;
      if (useLink) {
        target = PairingTarget.parseLink(link.text);
        pairingCode = target.code;
      } else {
        target = PairingTarget(
          PairingTarget.parseHub(hub.text),
          token.text.trim(),
        );
        pairingCode = target.code;
      }
      if ((requireConfirmation || target.isLan) &&
          !await _confirmHub(target.uri, lanHttp: target.isLan)) {
        return;
      }
      await widget.model.pair(
        target.uri.toString(),
        pairingCode,
        allowLanHttp: target.isLan,
      );
      if (mounted && widget.model.paired && Navigator.of(context).canPop())
        Navigator.of(context).pop();
    } on HubException catch (error) {
      if (mounted) setState(() => localError = error.message);
    } catch (_) {
      if (mounted)
        setState(() => localError = '连接失败，请检查电脑 Host、Wi-Fi 和防火墙后重试。');
    }
  }

  Future<bool> _confirmHub(Uri target, {required bool lanHttp}) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(lanHttp ? '连接局域网 HTTP Hub' : '连接电脑'),
          content: Text(
            lanHttp
                ? '连接到 ${target.origin}？此连接仅适用于你信任的局域网，传输不使用 HTTPS。'
                : '连接到 ${target.origin}？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('连接'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _scan() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScannerPage()));
    if (!mounted || raw == null) return;
    link.text = raw;
    if (!useLink) setState(() => useLink = true);
    await go(requireConfirmation: true);
  }

  Future<void> _reconnectLan() async {
    final raw = widget.model.pendingLanHub;
    if (raw == null) return;
    try {
      final target = PairingTarget.parseHub(raw);
      if (!await _confirmHub(target, lanHttp: true)) return;
      await widget.model.reconnectLan();
      if (mounted && widget.model.paired && Navigator.of(context).canPop())
        Navigator.of(context).pop();
    } on HubException catch (error) {
      if (mounted) setState(() => localError = error.message);
    } catch (_) {
      if (mounted)
        setState(() => localError = '连接失败，请检查电脑 Host、Wi-Fi 和防火墙后重试。');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AgentLinkSpace.xl,
            AgentLinkSpace.xl * 1.5,
            AgentLinkSpace.xl,
            AgentLinkSpace.xl,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 品牌标记：一个克制的图标块，替代原先占掉半屏的营销大色块。
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AgentLinkColors.lavender,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(
                      Icons.terminal_rounded,
                      color: AgentLinkColors.brand,
                      size: 28,
                    ),
                  ),
                ),
                const SizedBox(height: AgentLinkSpace.lg),
                Text(
                  '连接电脑',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AgentLinkSpace.sm),
                Text(
                  '手机和电脑连同一个 Wi-Fi，扫码即可接管上面的开发任务',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AgentLinkColors.muted,
                  ),
                ),
                const SizedBox(height: AgentLinkSpace.xl),
                // 扫码是最省事的路径，放在最显眼的位置。
                FilledButton.icon(
                  onPressed: widget.model.loading ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('扫码连接'),
                ),
                const SizedBox(height: AgentLinkSpace.xl),
                Row(
                  children: [
                    const Expanded(
                      child: Divider(color: AgentLinkColors.line),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AgentLinkSpace.md,
                      ),
                      child: Text(
                        '或手动填写',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AgentLinkColors.muted,
                        ),
                      ),
                    ),
                    const Expanded(
                      child: Divider(color: AgentLinkColors.line),
                    ),
                  ],
                ),
                const SizedBox(height: AgentLinkSpace.lg),
                if (useLink)
                  TextField(
                    controller: link,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '配对链接'),
                  )
                else ...[
                  TextField(
                    controller: hub,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '电脑 Hub 的 HTTPS 地址',
                      hintText: 'https://hub.example.com',
                    ),
                  ),
                  const SizedBox(height: AgentLinkSpace.md),
                  TextField(
                    controller: token,
                    obscureText: true,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: '配对码'),
                  ),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: widget.model.loading
                        ? null
                        : () => setState(() => useLink = !useLink),
                    child: Text(useLink ? '使用地址和配对码' : '粘贴配对链接'),
                  ),
                ),
                if (localError ?? widget.model.error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: AgentLinkSpace.sm),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: AgentLinkSpace.md),
                FilledButton(
                  onPressed: widget.model.loading ? null : go,
                  child: Text(widget.model.loading ? '正在连接…' : '连接工作台'),
                ),
                if (widget.model.pendingLanHub != null)
                  TextButton(
                    onPressed: widget.model.loading ? null : _reconnectLan,
                    child: const Text('重新连接已保存的局域网电脑'),
                  ),
                const SizedBox(height: AgentLinkSpace.sm),
                Text(
                  '凭据保存在设备安全存储中',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AgentLinkColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class Home extends StatefulWidget {
  const Home(this.model, {super.key});
  final AppModel model;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  String? projectPath;
  AppModel get model => widget.model;

  void showProjects() => setState(() {
    tab = 0;
    projectPath = null;
  });

  Future<void> forgetHub() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('忘记此 Hub？'),
        content: const Text('这会删除本机保存的连接信息、草稿和未确认消息。电脑上的任务不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('忘记并断开'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final id = model.hub;
      if (id != null && id.startsWith('device:')) {
        try {
          final registry = TrustedDeviceRegistry();
          await registry.load();
          await registry.forget(id.substring('device:'.length));
        } catch (_) {
          if (mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('无法清除设备凭据，请重试。')));
          return;
        }
      }
      await model.logout();
    }
  }

  Widget _workspace(bool wide) {
    if (model.selectedSession != null) {
      return Chat(model, key: ValueKey(model.selectedSession));
    }
    final path = projectPath;
    if (path != null) {
      return Sessions(model, projectPath: path);
    }
    return Projects(
      model: model,
      onOpen: (path) => setState(() => projectPath = path),
      onPending: () => setState(() => tab = 1),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final wide = bounds.maxWidth >= 800;
      final chatting = model.selectedSession != null && tab == 0;
      // 对话页标题直接用会话名，比「会话」这种泛化标题有用。
      final openSession = chatting
          ? model.sessions
                .where((s) => s.id == model.selectedSession)
                .firstOrNull
          : null;
      return PopScope(
        canPop: !chatting && projectPath == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && chatting) {
            model.closeSession();
          } else if (!didPop && projectPath != null) {
            showProjects();
          }
        },
        child: Scaffold(
          appBar: AppBar(
            leading: chatting
                ? IconButton(
                    tooltip: '返回项目',
                    onPressed: model.closeSession,
                    icon: const Icon(Icons.arrow_back),
                  )
                : projectPath != null && tab == 0
                ? IconButton(
                    tooltip: '返回工作台',
                    onPressed: showProjects,
                    icon: const Icon(Icons.arrow_back),
                  )
                : null,
            // 标题即当前位置：项目页显示项目名，对话页显示会话名，
            // 省掉页内重复的大标题。
            title: Text(
              tab == 1
                  ? '待处理'
                  : tab == 2
                  ? '连接'
                  : chatting
                  ? openSession?.title ?? '会话'
                  : projectPath?.split('/').last ?? '工作台',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            actions: [
              // 用量入口与刷新并列：两者都是「看一眼全局状态」，不属于某个会话。
              IconButton(
                tooltip: '用量',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => UsagePage(model)),
                ),
                icon: const Icon(Icons.insights_outlined),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: () async {
                  await model.refresh();
                  await model.refreshOpen();
                },
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '忘记此 Hub',
                onPressed: forgetHub,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          floatingActionButton: tab == 0 && (wide || !chatting)
              ? FloatingActionButton.extended(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => NewSessionDialog(model),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('新会话'),
                )
              : null,
          bottomNavigationBar: !wide && !chatting
              ? NavigationBar(
                  height: 66,
                  selectedIndex: tab,
                  onDestinationSelected: (value) => setState(() => tab = value),
                  destinations: [
                    const NavigationDestination(
                      icon: Icon(Icons.folder_outlined),
                      selectedIcon: Icon(Icons.folder),
                      label: '项目',
                    ),
                    NavigationDestination(
                      icon: model.sessions.any((s) => s.pending > 0)
                          ? Badge(
                              child: const Icon(Icons.pending_actions_outlined),
                            )
                          : const Icon(Icons.pending_actions_outlined),
                      selectedIcon: const Icon(Icons.pending_actions),
                      label: '待处理',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.link_outlined),
                      selectedIcon: Icon(Icons.link),
                      label: '连接',
                    ),
                  ],
                )
              : null,
          body: Column(
            children: [
              if (model.error != null)
                Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.errorContainer,
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    model.error!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Expanded(
                child: wide
                    ? Row(
                        children: [
                          NavigationRail(
                            selectedIndex: tab,
                            labelType: NavigationRailLabelType.all,
                            onDestinationSelected: (value) => setState(() {
                              tab = value;
                              if (value != 0) projectPath = null;
                            }),
                            destinations: const [
                              NavigationRailDestination(
                                icon: Icon(Icons.folder_outlined),
                                selectedIcon: Icon(Icons.folder),
                                label: Text('项目'),
                              ),
                              NavigationRailDestination(
                                icon: Icon(Icons.pending_actions_outlined),
                                selectedIcon: Icon(Icons.pending_actions),
                                label: Text('待处理'),
                              ),
                              NavigationRailDestination(
                                icon: Icon(Icons.link_outlined),
                                selectedIcon: Icon(Icons.link),
                                label: Text('连接'),
                              ),
                            ],
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: tab == 1
                                ? PendingOverview(
                                    model: model,
                                    onOpen: showProjects,
                                  )
                                : tab == 2
                                ? ConnectionOverview(
                                    model: model,
                                    onOpen: showProjects,
                                  )
                                : _workspace(true),
                          ),
                        ],
                      )
                    : tab == 1
                    ? PendingOverview(model: model, onOpen: showProjects)
                    : tab == 2
                    ? ConnectionOverview(model: model, onOpen: showProjects)
                    : _workspace(false),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class PendingOverview extends StatelessWidget {
  const PendingOverview({required this.model, required this.onOpen, super.key});
  final AppModel model;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final pending = model.sessions
        .where((session) => session.pending > 0)
        .toList();
    if (pending.isEmpty) {
      return const EmptyState(
        icon: Icons.check_circle_outline,
        title: '没有待处理请求',
        hint: 'Agent 需要你确认操作时会出现在这里',
      );
    }
    final total = pending.fold<int>(0, (sum, s) => sum + s.pending);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AgentLinkSpace.lg,
        AgentLinkSpace.lg,
        AgentLinkSpace.lg,
        100,
      ),
      children: [
        // 总量横幅：一眼看到还有多少要处理，不用自己数。
        Card(
          color: AgentLinkColors.sand,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AgentLinkSpace.lg,
              vertical: 14,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.pending_actions,
                  size: 20,
                  color: AgentLinkColors.amber,
                ),
                const SizedBox(width: AgentLinkSpace.md),
                Expanded(
                  child: Text(
                    '$total 项请求等待你确认',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AgentLinkSpace.lg),
        for (final session in pending)
          Padding(
            padding: const EdgeInsets.only(bottom: AgentLinkSpace.sm),
            child: ListCard(
              onTap: () async {
                model.setAgent(session.flavor);
                await model.openSession(session.id);
                if (context.mounted) onOpen();
              },
              child: Row(
                children: [
                  const StatusDot(SessionStatus.pending),
                  const SizedBox(width: AgentLinkSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${session.pending} 项等待确认 · ${session.cwd.split('/').last}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AgentLinkColors.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AgentLinkSpace.md),
                  const RowChevron(),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class ConnectionOverview extends StatelessWidget {
  const ConnectionOverview({
    required this.model,
    required this.onOpen,
    super.key,
  });
  final AppModel model;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unresolved = model.unresolvedMessages;
    final online = model.machines
        .where((machine) => machine.active)
        .map((machine) => machine.name)
        .join('、');
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AgentLinkSpace.lg,
        AgentLinkSpace.lg,
        AgentLinkSpace.lg,
        100,
      ),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AgentLinkSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StatusDot(
                      online.isEmpty
                          ? SessionStatus.ended
                          : SessionStatus.running,
                    ),
                    const SizedBox(width: AgentLinkSpace.sm),
                    Expanded(
                      child: Text(
                        online.isEmpty ? '当前电脑' : online,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AgentLinkSpace.sm),
                Text(
                  model.error ??
                      (online.isEmpty ? '没有在线的电脑，请确认电脑端已启动' : '连接正常'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: model.error == null
                        ? AgentLinkColors.muted
                        : AgentLinkColors.amber,
                  ),
                ),
                const SizedBox(height: AgentLinkSpace.lg),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: model.loading ? null : model.refresh,
                    child: const Text('重新连接'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AgentLinkSpace.md),
        OutlinedButton.icon(
          icon: const Icon(Icons.computer),
          label: const Text('切换电脑 / 管理已配对设备'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (pageContext) => DevicePage(
                model: model,
                onManual: () async {
                  await Navigator.of(
                    pageContext,
                  ).push(MaterialPageRoute(builder: (_) => Pairing(model)));
                  if (pageContext.mounted &&
                      model.paired &&
                      Navigator.of(pageContext).canPop())
                    Navigator.of(pageContext).pop();
                },
              ),
            ),
          ),
        ),
        // 没有未确认消息时不占位置，避免连接页出现一大段空文案。
        if (unresolved.isNotEmpty) ...[
          const SizedBox(height: AgentLinkSpace.xl),
          const SectionLabel('未确认消息'),
          Text(
            '发送结果尚未确认，打开对应会话查看原内容。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AgentLinkColors.muted,
            ),
          ),
          const SizedBox(height: AgentLinkSpace.md),
          for (final row in unresolved)
            Padding(
              padding: const EdgeInsets.only(bottom: AgentLinkSpace.sm),
              child: Builder(
                builder: (context) {
                  final session = model.sessions
                      .where((item) => item.id == row.sessionId)
                      .firstOrNull;
                  return ListCard(
                    onTap: session == null
                        ? () {}
                        : () async {
                            model.setAgent(session.flavor);
                            await model.openSession(session.id);
                            if (context.mounted) onOpen();
                          },
                    child: Row(
                      children: [
                        const Icon(
                          Icons.outbox_outlined,
                          size: 20,
                          color: AgentLinkColors.amber,
                        ),
                        const SizedBox(width: AgentLinkSpace.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                session?.title ?? '已关闭的任务',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                row.message.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AgentLinkColors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AgentLinkSpace.md),
                        if (session != null) const RowChevron(),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ],
    );
  }
}

class NewSessionDialog extends StatefulWidget {
  const NewSessionDialog(this.model, {super.key});
  final AppModel model;
  @override
  State<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<NewSessionDialog> {
  final directory = TextEditingController(),
      description = TextEditingController();
  String? machine, error;
  List<AgentAvailability> availability = [];
  bool checking = true, creating = false;
  int generation = 0;
  late String agent;
  @override
  void initState() {
    super.initState();
    agent = widget.model.selectedAgent;
    machine = widget.model.machines.where((m) => m.active).firstOrNull?.id;
    directory.text =
        widget.model.sessions
            .where((s) => s.flavor == agent && s.cwd.startsWith('/'))
            .firstOrNull
            ?.cwd ??
        '';
    unawaited(check());
  }

  Future<void> check() async {
    final ticket = ++generation;
    setState(() {
      checking = true;
      availability = [];
      error = null;
    });
    try {
      final client = widget.model.api;
      if (machine == null || client == null)
        throw HubException('电脑未在线，请先启动 Host');
      final values = await client.agentAvailability(machine!);
      if (mounted && ticket == generation && widget.model.api == client)
        setState(() => availability = values);
    } catch (e) {
      if (mounted && ticket == generation) setState(() => error = '$e');
    } finally {
      if (mounted && ticket == generation) setState(() => checking = false);
    }
  }

  @override
  void dispose() {
    directory.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> create() async {
    setState(() {
      creating = true;
      error = null;
    });
    try {
      final api = widget.model.api;
      final id = await widget.model.create(
        machine!,
        directory.text.trim(),
        agent: agent,
      );
      final selected = widget.model.selectedSession;
      if (id == null || selected != id || widget.model.api != api) {
        throw HubException('会话创建结果未确认，请刷新后查看任务。');
      }
      if (description.text.trim().isNotEmpty) {
        widget.model.setDraft(id, description.text);
        await widget.model.send(description.text);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = availability.where((a) => a.agent == agent).firstOrNull;
    return AlertDialog(
      title: const Text('开始一项任务'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 分组标签与输入框自带的 label 视觉区分开，避免看起来像同一层级。
            Text(
              '使用哪个 Agent',
              style: theme.textTheme.labelLarge?.copyWith(
                color: AgentLinkColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AgentLinkSpace.sm),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'codex', label: Text('Codex')),
                ButtonSegment(value: 'codebuddy', label: Text('CodeBuddy')),
              ],
              selected: {agent},
              onSelectionChanged: creating
                  ? null
                  : (value) {
                      setState(() {
                        agent = value.first;
                        availability = [];
                      });
                      unawaited(check());
                    },
            ),
            const SizedBox(height: AgentLinkSpace.lg),
            DropdownButtonFormField<String>(
              initialValue: machine,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '电脑'),
              items: widget.model.machines
                  .where((m) => m.active)
                  .map(
                    (m) => DropdownMenuItem(
                      value: m.id,
                      child: Text(m.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: creating
                  ? null
                  : (v) {
                      machine = v;
                      unawaited(check());
                    },
            ),
            const SizedBox(height: AgentLinkSpace.md),
            TextField(
              controller: directory,
              onChanged: (_) => setState(() {}),
              enabled: !creating,
              decoration: const InputDecoration(
                labelText: '电脑上的项目完整路径',
                helperText: '在电脑上运行 pwd 即可看到',
              ),
            ),
            const SizedBox(height: AgentLinkSpace.md),
            TextField(
              controller: description,
              enabled: !creating,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '任务描述（创建后发送给 Agent）',
              ),
            ),
            const SizedBox(height: AgentLinkSpace.md),
            if (checking)
              const LinearProgressIndicator()
            else if (available?.available != true)
              Text(
                available?.reason ?? '此电脑上的代理不可用',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AgentLinkColors.amber,
                ),
              ),
            if (error != null)
              Text(
                error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            if (creating)
              Padding(
                padding: const EdgeInsets.only(top: AgentLinkSpace.md),
                child: Text(
                  '正在启动，请稍候…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AgentLinkColors.muted,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: creating ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              !creating &&
                  !checking &&
                  available?.available == true &&
                  directory.text.trim().isNotEmpty
              ? create
              : null,
          child: const Text('创建并开始'),
        ),
      ],
    );
  }
}

class Projects extends StatelessWidget {
  const Projects({
    required this.model,
    required this.onOpen,
    required this.onPending,
    super.key,
  });
  final AppModel model;
  final ValueChanged<String> onOpen;
  final VoidCallback onPending;
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<SessionSummary>>{};
    for (final session in model.sessions.where(
      (session) => session.flavor == model.selectedAgent,
    )) {
      final path = session.cwd.replaceFirst(RegExp(r'/+$'), '');
      groups.putIfAbsent(path.isEmpty ? '未指定目录' : path, () => []).add(session);
    }
    final pending = model.sessions.fold<int>(
      0,
      (total, session) => total + session.pending,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AgentLinkSpace.lg,
            AgentLinkSpace.md,
            AgentLinkSpace.lg,
            AgentLinkSpace.sm,
          ),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'codex', label: Text('Codex')),
              ButtonSegment(value: 'codebuddy', label: Text('CodeBuddy')),
            ],
            selected: {model.selectedAgent},
            onSelectionChanged: (value) => model.setAgent(value.first),
          ),
        ),
        Expanded(
          child: groups.isEmpty
              ? const EmptyState(
                  icon: Icons.folder_open_outlined,
                  title: '还没有项目',
                  hint: '点击右下角「新会话」开始',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AgentLinkSpace.lg,
                    AgentLinkSpace.sm,
                    AgentLinkSpace.lg,
                    100,
                  ),
                  children: [
                    if (pending > 0)
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: AgentLinkSpace.md,
                        ),
                        child: Card(
                          color: AgentLinkColors.sand,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: onPending,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AgentLinkSpace.lg,
                                vertical: 14,
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.pending_actions,
                                    size: 20,
                                    color: AgentLinkColors.amber,
                                  ),
                                  const SizedBox(width: AgentLinkSpace.md),
                                  Expanded(
                                    child: Text(
                                      '$pending 项请求等待你确认',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right,
                                    size: 20,
                                    color: AgentLinkColors.amber,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    for (final entry in groups.entries)
                      _ProjectRow(
                        path: entry.key,
                        sessions: entry.value,
                        onTap: () => onOpen(entry.key),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// 项目行：项目名 + 一行汇总 + 状态点。
///
/// 曾经在这里直接列出会话标题，并在卡片里放按钮 —— 一个卡片里堆了 6 个元素，
/// 读起来很吵。项目名与汇总足够支撑「要不要点进去」这个判断，会话列表交给
/// 下一级页面。
class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.path,
    required this.sessions,
    required this.onTap,
  });

  final String path;
  final List<SessionSummary> sessions;
  final VoidCallback onTap;

  /// 项目整体状态：待处理 > 执行中 > 在线 > 已结束。
  SessionStatus get _status {
    final statuses = sessions.map(SessionStatus.of).toSet();
    for (final candidate in const [
      SessionStatus.pending,
      SessionStatus.running,
      SessionStatus.idle,
    ]) {
      if (statuses.contains(candidate)) return candidate;
    }
    return SessionStatus.ended;
  }

  /// 汇总行：优先暴露待处理数量，其次执行中，都没有时只报会话总数。
  String get _summary {
    final pending = sessions.fold<int>(0, (total, s) => total + s.pending);
    final running = sessions
        .where((s) => s.active && s.thinking)
        .length;
    final parts = <String>['${sessions.length} 个会话'];
    if (pending > 0) {
      parts.add('$pending 项待确认');
    } else if (running > 0) {
      parts.add('$running 个执行中');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AgentLinkSpace.md),
      child: ListCard(
        onTap: onTap,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    path.split('/').last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AgentLinkColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AgentLinkSpace.md),
            StatusDot(_status),
            const SizedBox(width: AgentLinkSpace.sm),
            const RowChevron(),
          ],
        ),
      ),
    );
  }
}

class Sessions extends StatefulWidget {
  const Sessions(this.model, {required this.projectPath, super.key});
  final AppModel model;
  final String projectPath;
  @override
  State<Sessions> createState() => _SessionsState();
}

class _SessionsState extends State<Sessions> {
  bool showHistory = false;

  @override
  Widget build(BuildContext context) {
    final sessions = widget.model.sessions
        .where(
          (session) =>
              session.flavor == widget.model.selectedAgent &&
              session.cwd.replaceFirst(RegExp(r'/+$'), '') ==
                  widget.projectPath,
        )
        .toList();
    final running = sessions.where((session) => session.active).toList();
    final history = sessions.where((session) => !session.active).toList();
    final shown = showHistory ? history : running;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AgentLinkSpace.lg,
            AgentLinkSpace.md,
            AgentLinkSpace.lg,
            AgentLinkSpace.sm,
          ),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text('进行中 ${running.length}'),
                ),
                ButtonSegment(value: true, label: Text('已结束 ${history.length}')),
              ],
              selected: {showHistory},
              onSelectionChanged: (value) =>
                  setState(() => showHistory = value.first),
            ),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? EmptyState(
                  icon: showHistory
                      ? Icons.history
                      : Icons.play_circle_outline,
                  title: showHistory ? '没有已结束的会话' : '没有进行中的会话',
                  hint: showHistory
                      ? '已经结束但可以恢复的会话会显示在这里'
                      : '在电脑上开启一个会话后会自动出现在这里',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AgentLinkSpace.lg,
                    AgentLinkSpace.sm,
                    AgentLinkSpace.lg,
                    100,
                  ),
                  children: [
                    for (final session in shown)
                      _SessionRow(
                        session: session,
                        onTap: () => widget.model.openSession(session.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// 会话行：状态点 + 标题 + 时间。
///
/// 原来这里有一个圆形头像、一个图标、两行标题和一句状态描述，一屏放不下几条。
/// 改成一行之后，标题本身是唯一的识别信息，状态交给左侧圆点，时间替代了那
/// 句「在线 · 可以继续输入」。
class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.onTap});

  final SessionSummary session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = SessionStatus.of(session);
    return Padding(
      padding: const EdgeInsets.only(bottom: AgentLinkSpace.md),
      child: ListCard(
        onTap: onTap,
        child: Row(
          children: [
            StatusDot(status),
            const SizedBox(width: AgentLinkSpace.md),
            Expanded(
              child: Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
            const SizedBox(width: AgentLinkSpace.md),
            Text(
              session.pending > 0
                  ? '${session.pending} 项待确认'
                  : formatRelativeTime(session.updatedAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: session.pending > 0
                    ? AgentLinkColors.amber
                    : AgentLinkColors.muted,
                fontWeight: session.pending > 0
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
            const SizedBox(width: AgentLinkSpace.sm),
            const RowChevron(),
          ],
        ),
      ),
    );
  }
}

class Chat extends StatefulWidget {
  const Chat(this.model, {super.key});
  final AppModel model;
  @override
  State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> {
  late final String sessionId = widget.model.selectedSession!;
  late final TextEditingController text = TextEditingController(
    text: widget.model.draftFor(sessionId),
  );
  final scroll = ScrollController();
  bool sending = false;

  /// 已渲染过的消息条数，用来判断是否出现了新内容。
  int _seenMessages = 0;

  /// 已弹出过确认层的请求 id，避免每轮刷新都重复弹。
  final _promptedRequests = <String>{};

  @override
  void initState() {
    super.initState();
    text.addListener(() => widget.model.setDraft(sessionId, text.text));
    widget.model.addListener(_onModelChanged);
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    text.dispose();
    scroll.dispose();
    super.dispose();
  }

  /// 模型变化时跟随最新消息滚动，并在出现新的审批请求时弹出确认层。
  void _onModelChanged() {
    _followLatestMessage();
    if (widget.model.requests.isNotEmpty) _promptRequest();
  }

  /// 有新消息时滚到底部。
  ///
  /// 只在用户本来就贴着底部时跟随：他主动往上翻看历史时不该被拽回来，
  /// 但新增的回复必须能自己显现，不该等他手动滑。
  void _followLatestMessage() {
    final count = widget.model.messages.length;
    if (count == _seenMessages) return;
    _seenMessages = count;
    if (count == 0) return;
    final atBottom =
        !scroll.hasClients ||
        scroll.position.maxScrollExtent - scroll.offset <= 120;
    if (!atBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  /// 出现新的审批请求时自动弹出确认层。
  void _promptRequest() {
    final request = widget.model.requests.first;
    if (!_promptedRequests.add(request.id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openRequestSheet(request);
    });
  }

  /// 打开某个待确认请求的操作层。
  ///
  /// 确认层用 AnimatedBuilder 订阅模型：提交后电脑端裁决会改变请求状态，
  /// 内容要跟着刷新，而不是停在打开时的快照。
  void _openRequestSheet(PendingRequest request) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => AnimatedBuilder(
        animation: widget.model,
        builder: (context, _) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(AgentLinkSpace.md),
              child: RequestCard(
                model: widget.model,
                request: widget.model.requests
                        .where((item) => item.id == request.id)
                        .firstOrNull ??
                    request,
                key: ValueKey('${request.sessionId}/${request.id}'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> send() async {
    if (sending || text.text.trim().isEmpty) return;
    setState(() => sending = true);
    // 会话不在线时由模型先恢复再发送；恢复可能把会话切到新的 id，所以回填草稿
    // 时按当时的选中会话取值，而不是捕获在 initState 里的旧 id。
    await widget.model.sendOrResume(text.text);
    if (mounted) {
      text.text = widget.model.draftFor(
        widget.model.selectedSession ?? sessionId,
      );
      setState(() => sending = false);
      if (scroll.hasClients)
        unawaited(
          scroll.animateTo(
            scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          ),
        );
    }
  }

  Future<void> loadEarlier() async {
    if (!scroll.hasClients) return;
    final previousOffset = scroll.offset;
    final previousExtent = scroll.position.maxScrollExtent;
    await widget.model.loadEarlier();
    if (!mounted || !scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      final addedExtent = scroll.position.maxScrollExtent - previousExtent;
      final target = (previousOffset + addedExtent)
          .clamp(0.0, scroll.position.maxScrollExtent)
          .toDouble();
      scroll.jumpTo(target);
    });
  }

  Future<void> rename() async {
    final controller = TextEditingController(
      text:
          widget.model.sessions
              .where((s) => s.id == sessionId)
              .firstOrNull
              ?.title ??
          '',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // Dialog route may still be animating out; dispose after transition.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (mounted &&
        result != null &&
        result.isNotEmpty &&
        widget.model.selectedSession == sessionId)
      await widget.model.rename(result);
  }

  /// 选择当前会话的权限模式。
  ///
  /// 只列出该 Agent 支持的模式；CodeBuddy 等固定为「执行前询问」的类型没有
  /// 可切换项，入口会被隐藏。会跳过审批的模式用警示色标出。
  Future<void> _pickPermissionMode() async {
    final session = widget.model.sessions
        .where((s) => s.id == sessionId)
        .firstOrNull;
    final modes = permissionModesForFlavor(session?.flavor ?? '');
    if (modes.isEmpty) return;
    final current =
        widget.model.permissionModeFor(sessionId) ?? modes.first.mode;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '权限模式',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('控制 Agent 执行操作前是否需要你确认'),
            ),
            const Divider(height: 1, color: AgentLinkColors.line),
            // CodeBuddy 有 8 档，窄屏上会超出屏幕，所以让列表自身可滚动。
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final option in modes)
                    ListTile(
                      leading: Icon(
                        option.warning
                            ? Icons.warning_amber_rounded
                            : Icons.shield_outlined,
                        color: option.warning
                            ? AgentLinkColors.amber
                            : AgentLinkColors.teal,
                      ),
                      title: Text(option.label),
                      subtitle: option.description == null
                          ? null
                          : Text(option.description!),
                      trailing: option.mode == current
                          ? const Icon(Icons.check, color: AgentLinkColors.brand)
                          : null,
                      onTap: () => Navigator.pop(context, option.mode),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AgentLinkSpace.sm),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    await widget.model.setPermissionMode(picked);
  }

  /// 选择当前会话使用的模型。
  ///
  /// 模型列表由电脑端给出（Codex 走模型 RPC，CodeBuddy 取自会话的 ACP 配置），
  /// 所以要先请求一次。拉不到时如实说明，而不是弹一个空白面板 —— 用户分不清
  /// 「没有可选模型」和「还没准备好」。
  Future<void> _pickModel() async {
    final models = await widget.model.availableModels(sessionId);
    if (!mounted) return;
    if (models == null || models.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这个会话暂时取不到模型列表')));
      return;
    }
    final current = widget.model.modelFor(sessionId);
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '模型',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('选择这个会话使用的模型'),
            ),
            const Divider(height: 1, color: AgentLinkColors.line),
            // CodeBuddy 有十几个模型且带计费说明，窄屏上会超出屏幕。
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final option in models)
                    ListTile(
                      title: Text(option.label),
                      subtitle: option.note == null ? null : Text(option.note!),
                      trailing: option.id == current
                          ? const Icon(Icons.check, color: AgentLinkColors.brand)
                          : null,
                      onTap: () => Navigator.pop(context, option.id),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AgentLinkSpace.sm),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    await widget.model.setModel(picked);
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final session = model.sessions.where((s) => s.id == sessionId).firstOrNull;
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session?.title ?? '会话',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        [
                          session?.flavor == 'codebuddy'
                              ? 'CodeBuddy'
                              : 'Codex',
                          // 恢复期间先本地报「正在启动」，不必等下一次轮询把状态
                          // 带回来 —— 电脑端拉起进程要几秒，这段空窗最容易让人
                          // 以为操作没生效。
                          if (model.resuming.contains(sessionId))
                            '正在启动…'
                          else if (session?.active != true)
                            '已归档'
                          else if (session?.thinking == true)
                            '运行中'
                          else
                            '在线',
                          // 当前模型；电脑端没上报时不占位，避免出现空的一节。
                          ?model.modelFor(sessionId),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '重命名',
                  onPressed: rename,
                  icon: const Icon(Icons.edit_outlined),
                ),
                // 权限模式入口：仅对该 Agent 支持切换时出现。
                if (permissionModesForFlavor(session?.flavor ?? '')
                    .isNotEmpty)
                  IconButton(
                    tooltip: '权限模式',
                    visualDensity: VisualDensity.compact,
                    onPressed: _pickPermissionMode,
                    icon: const Icon(Icons.shield_outlined),
                  ),
                // 模型入口：只对已知支持切换模型的 Agent 显示，避免在必然拿不到
                // 列表的会话上给出一个点了会报错的按钮。
                if (session?.flavor == 'codex' ||
                    session?.flavor == 'codebuddy')
                  IconButton(
                    tooltip: '模型',
                    visualDensity: VisualDensity.compact,
                    onPressed: _pickModel,
                    icon: const Icon(Icons.memory),
                  ),
                // 停止按钮在有会话时始终保留，但只有执行中才可点；会话结束后
                // 换成恢复入口。不可用的动作保持可见并置灰，避免按钮位置跳动。
                if (session?.active == true)
                  IconButton(
                    tooltip: session?.thinking == true
                        ? '停止当前执行'
                        : '当前空闲，无需停止',
                    onPressed: session?.thinking == true
                        ? model.abortSelected
                        : null,
                    icon: const Icon(Icons.stop_circle_outlined),
                  )
                else
                  IconButton(
                    tooltip: model.resuming.contains(sessionId)
                        ? '正在继续…'
                        : '继续会话',
                    onPressed: model.resuming.contains(sessionId)
                        ? null
                        : model.resumeSelected,
                    icon: const Icon(Icons.play_circle_outline),
                  ),
              ],
            ),
          ),
        ),
        // 待确认请求不再固定占据消息列表上方。长命令会一直压着对话区，而用户
        // 真正想看的往往是下面的新回复；改成：新请求自动弹出确认层，收起后由
        // 这个提示条负责重新打开。
        if (model.requests.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AgentLinkSpace.md,
              0,
              AgentLinkSpace.md,
              AgentLinkSpace.sm,
            ),
            child: ListCard(
              onTap: () => _openRequestSheet(model.requests.first),
              child: Row(
                children: [
                  const Icon(
                    Icons.pending_actions,
                    size: 20,
                    color: AgentLinkColors.amber,
                  ),
                  const SizedBox(width: AgentLinkSpace.md),
                  Expanded(
                    child: Text(
                      '${model.requests.length} 项操作等待确认 · 点击处理',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const RowChevron(),
                ],
              ),
            ),
          ),
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(12),
            children: [
              if (model.hasEarlierMessages)
                Center(
                  child: TextButton(
                    onPressed: loadEarlier,
                    child: const Text('加载更早消息'),
                  ),
                ),
              if (model.messages.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('开始对话，或等待电脑返回消息', textAlign: TextAlign.center),
                ),
              for (final entry in buildChatEntries(model.messages))
                _MessageTile(entry: entry, model: model),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: text,
                    minLines: 1,
                    maxLines: 5,
                    // 输入始终可用：历史会话离线时，发送会自动先恢复会话，
                    // 不再要求用户先点一次「继续」再输入。
                    decoration: InputDecoration(
                      hintText: session?.active == true
                          ? '输入消息…'
                          : '输入消息，发送后自动启动会话…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                switch (resolveComposerAction(
                  thinking: session?.thinking == true,
                )) {
                  // 执行中：主按钮变成停止，避免误发新消息。
                  ChatComposerAction.stop => IconButton.filled(
                    tooltip: '停止执行',
                    onPressed: model.abortSelected,
                    icon: const Icon(Icons.stop),
                  ),
                  ChatComposerAction.send => IconButton.filled(
                    tooltip: session?.active == true ? '发送' : '启动会话并发送',
                    onPressed: !sending ? send : null,
                    // 启动会话期间也在这里转圈：电脑端拉起进程要几秒，
                    // 没有即时反馈用户会以为点击没生效而反复点。
                    icon: sending || model.resuming.contains(sessionId)
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                },
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class RequestCard extends StatefulWidget {
  const RequestCard({super.key, required this.model, required this.request});
  final AppModel model;
  final PendingRequest request;
  @override
  State<RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<RequestCard> {
  late final answers = InputAnswers(widget.request);

  /// 命令详情默认收起。
  ///
  /// 确认这个动作本身不需要通读整条命令，而一条长命令会把对话区压满好几屏。
  /// 需要核对时点开即可，可核查性没有丢；危险提示不受此开关影响，始终可见。
  bool _showDetail = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.request;
    final questions = answers.questions;
    final locked = widget.model.submittedRequests.contains(r.id);
    final isQuestions = r.needsAnswer;
    final hasValidQuestions = answers.supported;
    final answered = answers.valid;
    final summary = isQuestions ? null : summarizeRequest(r);

    return Card(
      // 纯白背景：审批是对话流里的一个环节，不需要靠底色抢注意力；
      // 需要留意的信息（工具名、危险提示）用强调色单独表达。
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AgentLinkColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AgentLinkSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  locked ? Icons.hourglass_top : Icons.help_outline,
                  size: 18,
                  color: AgentLinkColors.amber,
                ),
                const SizedBox(width: AgentLinkSpace.sm),
                Expanded(
                  child: Text(
                    locked ? '已提交，等待电脑确认' : '需要你确认',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                // 工具名做成小标签，比拼进标题更好扫读。
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    r.tool,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AgentLinkColors.amber,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AgentLinkSpace.md),
            if (isQuestions && hasValidQuestions) ...[
              for (final q in questions) ...[
                Text(
                  '${q.question}${q.required ? '' : '（选填）'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: AgentLinkSpace.sm),
                if (q.options.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final option in q.options)
                        FilterChip(
                          label: Text(option.label),
                          tooltip: option.description,
                          selected: answers.isSelected(q.key, option.label),
                          onSelected: locked
                              ? null
                              : (selected) => setState(() {
                                  answers.select(q.key, option.label, selected);
                                }),
                        ),
                    ],
                  ),
                const SizedBox(height: AgentLinkSpace.sm),
                TextFormField(
                  key: ValueKey('${r.id}/${q.key}'),
                  initialValue: q.prefill,
                  enabled: !locked,
                  minLines: q.editor ? 3 : 1,
                  maxLines: q.editor ? 8 : 3,
                  decoration: const InputDecoration(labelText: '填写回答'),
                  onChanged: (value) =>
                      setState(() => answers.note(q.key, value)),
                ),
                const SizedBox(height: AgentLinkSpace.md),
              ],
            ] else if (summary != null) ...[
              // 详情默认收起，只留一个展开入口：确认动作本身不需要通读整条
              // 命令，而长命令会把对话区压满好几屏。展开后仍是原来那段
              // 白底等宽文本，可核查性没有牺牲。
              InkWell(
                onTap: () => setState(() => _showDetail = !_showDetail),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AgentLinkSpace.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _showDetail ? '收起命令详情' : '查看命令详情',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AgentLinkColors.brand,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        _showDetail ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: AgentLinkColors.brand,
                      ),
                    ],
                  ),
                ),
              ),
              if (_showDetail) ...[
                // 待确认的操作放在白底区里，与琥珀底形成对比，像一段待批的指令。
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AgentLinkSpace.md),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AgentLinkColors.line),
                  ),
                  child: SelectableText(
                    summary.headline,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
                if (summary.details.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AgentLinkSpace.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final (label, value) in summary.details)
                          Text(
                            '$label：$value',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AgentLinkColors.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
            if (isQuestions && !hasValidQuestions)
              Text(
                '此请求的问题格式暂不支持，请在电脑端回答。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AgentLinkColors.amber,
                ),
              ),
            // 命中危险模式时显式提醒，避免「允许一次」被顺手点掉。
            if (summary != null && summary.dangerous)
              Padding(
                padding: const EdgeInsets.only(top: AgentLinkSpace.sm),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: AgentLinkColors.amber,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '这条操作可能造成不可逆的改动，请确认不是误操作',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AgentLinkColors.amber,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AgentLinkSpace.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: locked
                      ? null
                      : () => widget.model.decide(r, false),
                  child: const Text('拒绝'),
                ),
                const SizedBox(width: AgentLinkSpace.sm),
                FilledButton(
                  onPressed:
                      locked ||
                          (isQuestions && (!hasValidQuestions || !answered))
                      ? null
                      : () => widget.model.decide(
                          r,
                          true,
                          answers: isQuestions && hasValidQuestions
                              ? answers.format()
                              : null,
                        ),
                  child: Text(isQuestions ? '提交回答' : '允许一次'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 审批卡片要展示的操作摘要。
class RequestSummary {
  const RequestSummary(
    this.headline, {
    this.details = const [],
    this.dangerous = false,
  });

  /// 最关键的一行：命令、文件路径或访问目标。
  final String headline;

  /// 补充信息，标签已本地化。
  final List<(String, String)> details;

  /// 命中危险模式时为 true。
  final bool dangerous;
}

/// 明显会造成不可逆后果的命令片段。
const dangerousCommandPatterns = [
  'rm -rf',
  'rm -fr',
  'sudo ',
  'mkfs',
  'dd if=',
  '> /dev/',
  'chmod -r 777',
  'git push --force',
  'git reset --hard',
  'shutdown',
  'reboot',
];

/// 从若干候选键里取第一个非空字符串。
String _firstStringArg(Map<String, dynamic> args, List<String> keys) {
  for (final key in keys) {
    final value = args[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return '';
}

/// 把工具的原始 JSON 参数压成一条人能快速判断的信息。
///
/// 此前这里直接渲染 `JsonEncoder` 的缩进输出，用户面对满屏 JSON 很难回答
/// 「到底要做什么」。现在按工具类型提取要点：命令类给命令本身，文件类给路径
/// 与改动规模，网络类给目标地址；无法识别的工具退化成键值对而非裸 JSON。
///
/// @param request 待确认的请求
/// @returns 可直接渲染的摘要
RequestSummary summarizeRequest(PendingRequest request) {
  final args = request.args;
  final lower = request.tool.toLowerCase();
  final path = _firstStringArg(args, [
    'file_path',
    'path',
    'filePath',
    'notebook_path',
  ]);
  final cwd = _firstStringArg(args, ['cwd', 'working_directory', 'directory']);
  final details = <(String, String)>[];
  if (cwd.isNotEmpty && cwd != path) details.add(('工作目录', cwd));

  // 命令类：命令行本身就是用户唯一要看的东西。
  if (lower.contains('bash') ||
      lower.contains('shell') ||
      lower.contains('execute') ||
      lower.contains('terminal')) {
    final command = _firstStringArg(args, ['command', 'cmd', 'script']);
    return RequestSummary(
      command.isEmpty ? '执行一条命令' : command,
      details: details,
      dangerous: dangerousCommandPatterns.any(command.toLowerCase().contains),
    );
  }

  // 写入 / 编辑类：路径 + 改动规模。
  if (lower.contains('write') ||
      lower.contains('create') ||
      lower.contains('edit') ||
      lower.contains('replace') ||
      lower.contains('patch')) {
    final content = _firstStringArg(args, [
      'content',
      'new_string',
      'new_str',
      'patch',
    ]);
    if (content.isNotEmpty) {
      details.add(('写入内容', '${content.split('\n').length} 行'));
    }
    return RequestSummary(path.isEmpty ? '修改文件' : path, details: details);
  }

  if (lower.contains('read') ||
      lower.contains('glob') ||
      lower.contains('grep') ||
      lower.contains('search') ||
      lower.contains('list')) {
    return RequestSummary(path.isEmpty ? '读取内容' : path, details: details);
  }

  if (lower.contains('fetch') ||
      lower.contains('web') ||
      lower.contains('http')) {
    final url = _firstStringArg(args, ['url', 'uri']);
    return RequestSummary(url.isEmpty ? '访问网络' : url, details: details);
  }

  // 其他工具：先挑一个像目标的字段，剩下按键值对列出（仍比裸 JSON 易读）。
  final headline = _firstStringArg(args, [
    'command',
    'url',
    'query',
    'pattern',
    'file_path',
    'path',
  ]);
  if (headline.isNotEmpty) return RequestSummary(headline, details: details);
  return RequestSummary('${request.tool} 请求执行', details: [
    ...details,
    for (final entry in args.entries.take(6)) (entry.key, '${entry.value}'),
  ]);
}

/// 单条对话项的渲染分派。
///
/// 按 [ChatMessage.view] 选择组件，与电脑端 Web UI 的分类保持一致：
/// 用户气泡、Markdown 正文、工具卡片、可折叠思考面板与居中状态行。
class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.entry, required this.model});

  final ChatEntry entry;
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final message = entry.message;

    if (message.view == MessageView.status)
      return StatusLine(text: message.text, icon: message.statusIcon);

    final card = switch (message.view) {
      MessageView.reasoning => ReasoningPanel(
        message.text,
        durationMs: entry.reasoningDurationMs,
      ),
      MessageView.toolCall || MessageView.toolResult => ToolCallCard(
        message: message,
        result: entry.result,
      ),
      _ => _textCard(context, message),
    };
    return Align(
      alignment: message.view == MessageView.user
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kMessageMaxWidth),
        child: card,
      ),
    );
  }

  /// 用户与助手的文本卡片；助手正文按 Markdown 渲染。
  Widget _textCard(BuildContext context, ChatMessage message) {
    final isUser = message.view == MessageView.user;
    return Card(
      color: isUser ? Theme.of(context).colorScheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${isUser ? '你' : '代理'}${message.pending
                  ? ' · 待确认'
                  : message.queued
                  ? ' · 排队中'
                  : ''}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 6),
            if (isUser)
              SelectableText(message.text)
            else
              AgentMarkdown(message.text),
            if (model.failedSends.contains(message.localId))
              TextButton(
                onPressed: () =>
                    model.send(message.text, retryLocalId: message.localId),
                child: const Text('重试发送'),
              ),
            if (isUser && message.queued && !message.pending)
              TextButton(
                onPressed: () => model.cancelMessage(message),
                child: const Text('取消排队消息'),
              ),
          ],
        ),
      ),
    );
  }
}
