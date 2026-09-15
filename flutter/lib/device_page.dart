import 'dart:async';

import 'package:flutter/material.dart';

import 'agentlink_theme.dart';
import 'app_model.dart';
import 'connection_policy.dart';
import 'device_discovery.dart';
import 'domain.dart';
import 'trusted_devices.dart';

class DevicePage extends StatefulWidget {
  const DevicePage({
    required this.model,
    required this.onManual,
    this.isRoot = false,
    this.registry,
    this.pairingService,
    this.discoveryFactory,
    super.key,
  });
  final AppModel model;
  final VoidCallback onManual;
  final bool isRoot;
  final TrustedDeviceRegistry? registry;
  final DevicePairingService? pairingService;
  final DeviceDiscovery Function()? discoveryFactory;
  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  late final _registry = widget.registry ?? TrustedDeviceRegistry();
  late final _pairing = widget.pairingService ?? DevicePairingService();
  final Map<String, NearbyComputer> _nearby = {};
  DeviceDiscovery? _discovery;
  PendingDevicePair? _pending;
  bool _ready = false, _searching = false, _busy = false;
  String? _error;
  int _generation = 0, _scanGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _registry.load();
      if (!mounted) return;
      setState(() => _ready = true);
      await _scan();
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取已配对设备，请重启 App 后重试。');
    }
  }

  Future<void> _scan() async {
    final generation = ++_scanGeneration;
    _discovery?.close();
    final discovery = widget.discoveryFactory?.call() ?? DeviceDiscovery();
    _discovery = discovery;
    setState(() {
      _searching = true;
      _nearby.clear();
      _error = null;
    });
    try {
      await discovery.scan((computer) {
        if (!mounted || generation != _scanGeneration || _nearby.length >= 64)
          return;
        setState(() => _nearby[computer.hostId] = computer);
      });
    } catch (_) {
      if (mounted && generation == _scanGeneration)
        setState(() => _error = '暂时无法搜索局域网，请检查 Wi-Fi，或使用扫码连接。');
    } finally {
      if (mounted && generation == _scanGeneration)
        setState(() => _searching = false);
    }
  }

  Future<void> _connect(TrustedComputer saved) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final candidate = saved.at(_nearby[saved.hostId]?.uri ?? saved.uri);
      await widget.model.pairVerifiedDevice(
        _pairing.api(candidate),
        candidate.hostId,
      );
      // Only update a changed address after the certificate and authorization
      // have been checked. Drafts/outbox use the stable certificate identity.
      await _registry.save(candidate);
      if (mounted && !widget.isRoot) Navigator.of(context).pop();
    } catch (_) {
      if (mounted)
        setState(() => _error = '连接未成功。请确认电脑在线；身份变化或授权被撤销时，需要在电脑确认后重新配对。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 已保存的局域网电脑地址；无待重连目标时返回 null。
  String? _savedLanOrigin() {
    final raw = widget.model.pendingLanHub;
    if (raw == null) return null;
    try {
      return PairingTarget.parseHub(raw).origin;
    } on HubException {
      return raw;
    }
  }

  /// 重连上次确认过的局域网电脑。
  ///
  /// 冷启动不会自动向已保存的 HTTP 地址发送凭据（见 [AppModel.restore]），
  /// 因此这里把确认动作放在首页，避免用户必须先进入手动配对页再找到入口。
  Future<void> _reconnectSavedLan() async {
    if (widget.model.pendingLanHub == null) return;
    final origin = _savedLanOrigin() ?? '已保存的地址';
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新连接已保存的电脑？'),
        content: Text('目标：$origin\n\n这是局域网 HTTP 连接，请确认当前 Wi-Fi 与电脑地址一致。'),
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
    );
    if (yes != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.model.reconnectLan();
    } catch (_) {
      if (mounted)
        setState(() => _error = '连接未成功，请确认电脑在线并已运行“启动局域网连接”。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _begin(NearbyComputer computer) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    PendingDevicePair? pair;
    try {
      pair = await _pairing.begin(computer);
      if (!mounted || generation != _generation) {
        pair.close();
        return;
      }
      setState(() => _pending = pair);
      while (mounted && generation == _generation) {
        final saved = await _pairing.poll(pair);
        if (!mounted || generation != _generation) return;
        if (saved != null) {
          await _registry.save(saved);
          if (!mounted || generation != _generation) return;
          setState(() => _pending = null);
          await _connect(saved);
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } catch (e) {
      if (mounted && generation == _generation)
        setState(
          () => _error = e is HubException
              ? e.message
              : '无法连接电脑，请检查电脑服务和 Wi-Fi 后重试。',
        );
    } finally {
      pair?.close();
      if (mounted && generation == _generation)
        setState(() {
          _pending = null;
          _busy = false;
        });
    }
  }

  void _cancel() {
    _generation++;
    final pair = _pending;
    pair?.close();
    if (pair != null) unawaited(_pairing.cancel(pair).catchError((_) {}));
    setState(() {
      _pending = null;
      _busy = false;
    });
  }

  Future<void> _forget(TrustedComputer computer) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('忘记这台电脑？'),
        content: const Text('下次连接需要在电脑上重新确认。也可在电脑管理页撤销此手机的授权。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('忘记'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await _registry.forget(computer.hostId);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = '无法清除本地设备信息，请重试。');
    }
  }

  @override
  void dispose() {
    _generation++;
    _scanGeneration++;
    _discovery?.close();
    final pair = _pending;
    pair?.close();
    if (pair != null) unawaited(_pairing.cancel(pair).catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final saved = _registry.computers;
    final fresh = _nearby.values.where(
      (c) => !saved.any((s) => s.hostId == c.hostId),
    );
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('连接你的电脑'),
          actions: [
            IconButton(
              onPressed: _ready && !_busy && !_searching ? _scan : null,
              icon: const Icon(Icons.refresh),
              tooltip: '重新搜索',
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AgentLinkSpace.lg,
              AgentLinkSpace.lg,
              AgentLinkSpace.lg,
              AgentLinkSpace.xl,
            ),
            children: [
              // 页内不再重复 AppBar 的标题，只留一句必要的说明。
              Text(
                '手机和电脑连接同一 Wi-Fi。首次在电脑确认，以后轻点即可连接。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AgentLinkColors.muted,
                ),
              ),
              const SizedBox(height: AgentLinkSpace.lg),
              if (_pending case final pending?)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AgentLinkSpace.lg),
                    child: Column(
                      children: [
                        Text(
                          '等待 ${pending.computer.name} 确认',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: AgentLinkSpace.md),
                        SelectableText(
                          '${pending.digits.substring(0, 4)}  ${pending.digits.substring(4)}',
                          style: Theme.of(context).textTheme.headlineLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: 4,
                              ),
                        ),
                        const SizedBox(height: AgentLinkSpace.md),
                        Text(
                          '请核对电脑管理页与这里的数字完全一致，再在电脑上点击允许。数字不同请取消。',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AgentLinkColors.muted),
                        ),
                        TextButton(
                          onPressed: _cancel,
                          child: const Text('取消连接'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_busy && _pending == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AgentLinkSpace.sm),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: AgentLinkSpace.sm,
                  ),
                  child: Text(
                    _error!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (widget.model.pendingLanHub != null) ...[
                ListCard(
                  onTap: _busy ? null : _reconnectSavedLan,
                  child: Row(
                    children: [
                      const Icon(
                        Icons.wifi_tethering,
                        size: 20,
                        color: AgentLinkColors.muted,
                      ),
                      const SizedBox(width: AgentLinkSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '上次连接的电脑',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '${_savedLanOrigin() ?? ''} · 点击重连',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: AgentLinkColors.muted),
                            ),
                          ],
                        ),
                      ),
                      const RowChevron(),
                    ],
                  ),
                ),
                const SizedBox(height: AgentLinkSpace.lg),
              ],
              if (saved.isNotEmpty) ...[
                const SectionLabel('已配对的电脑'),
                for (final computer in saved)
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: AgentLinkSpace.md,
                    ),
                    child: ListCard(
                      onTap: _busy ? null : () => _connect(computer),
                      child: Row(
                        children: [
                          StatusDot(
                            _nearby.containsKey(computer.hostId)
                                ? SessionStatus.running
                                : SessionStatus.ended,
                          ),
                          const SizedBox(width: AgentLinkSpace.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  computer.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  _nearby.containsKey(computer.hostId)
                                      ? '已在附近发现 · 点击连接'
                                      : '点击尝试上次地址',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: AgentLinkColors.muted),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.more_horiz, size: 20),
                            tooltip: '忘记电脑',
                            visualDensity: VisualDensity.compact,
                            onPressed: _busy ? null : () => _forget(computer),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: AgentLinkSpace.sm),
              ],
              SectionLabel(_searching ? '正在寻找附近电脑…' : '附近的电脑'),
              if (_searching)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AgentLinkSpace.md),
                  child: LinearProgressIndicator(),
                ),
              for (final computer in fresh)
                Padding(
                  padding: const EdgeInsets.only(bottom: AgentLinkSpace.md),
                  child: ListCard(
                    onTap: _ready && !_busy ? () => _begin(computer) : null,
                    child: Row(
                      children: [
                        const StatusDot(SessionStatus.idle),
                        const SizedBox(width: AgentLinkSpace.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                computer.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                '首次连接 · 在电脑确认',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: AgentLinkColors.muted),
                              ),
                            ],
                          ),
                        ),
                        const RowChevron(),
                      ],
                    ),
                  ),
                ),
              if (!_searching && fresh.isEmpty)
                const EmptyState(
                  icon: Icons.computer_outlined,
                  title: '没有发现新的电脑',
                  hint: '请运行电脑端「启动局域网连接」，然后重新搜索',
                ),
              const SizedBox(height: AgentLinkSpace.lg),
              OutlinedButton.icon(
                onPressed: _busy ? null : widget.onManual,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码或手动连接'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
