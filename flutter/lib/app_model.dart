import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'domain.dart';
import 'connection_policy.dart';
import 'hapi_api.dart';

typedef HapiApiFactory = HapiApi Function(Uri hub, String accessToken);

class _OutboxItem {
  const _OutboxItem({
    required this.localId,
    required this.text,
    required this.createdAt,
  });
  final String localId;
  final String text;
  final int createdAt;
  Map<String, dynamic> toJson() => {
    'localId': localId,
    'text': text,
    'createdAt': createdAt,
  };
  static _OutboxItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final row = value.cast<String, dynamic>();
    final localId = row['localId'],
        text = row['text'],
        createdAt = row['createdAt'];
    if (localId is! String || text is! String || createdAt is! num) return null;
    return _OutboxItem(
      localId: localId,
      text: text,
      createdAt: createdAt.toInt(),
    );
  }
}

/// Stale-safe owner for one active Hub connection.
/// Credentials, drafts, and outbox rows are committed as one JSON value.
class AppModel extends ChangeNotifier with WidgetsBindingObserver {
  AppModel({
    FlutterSecureStorage? storage,
    HapiApi? initialApi,
    HapiApiFactory? apiFactory,
    bool persistState = true,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _apiFactory = apiFactory ?? ((hub, token) => HapiApi(hub, token)),
       _persistState = persistState,
       api = initialApi,
       hub = initialApi?.baseUrl.toString() {
    WidgetsBinding.instance.addObserver(this);
  }

  static const _stateKey = 'hapi.companion.state.v1';
  static const _stateVersion = 1;
  final FlutterSecureStorage _storage;
  final HapiApiFactory _apiFactory;
  final bool _persistState;

  HapiApi? api;
  String? hub;
  String? pendingLanHub;
  String? selectedSession;
  String selectedAgent = 'codex';
  List<SessionSummary> sessions = [];
  List<Machine> machines = [];
  List<ChatMessage> messages = [];
  List<PendingRequest> requests = [];
  final Set<String> failedSends = <String>{};
  final Set<String> submittedRequests = <String>{};
  final Set<String> resuming = <String>{};

  final Map<String, String> _credentials = {};
  final Map<String, Map<String, String>> _drafts = {};
  final Map<String, Map<String, Map<String, _OutboxItem>>> _outbox = {};
  int? _beforeSeq, _beforeAt, _afterSeq, _afterAt, _messageEpoch;
  bool hasEarlierMessages = false;
  bool loading = false;
  String? error;
  Timer? _poll;
  Timer? _draftPersist;
  Future<void> _storageTail = Future<void>.value();
  int _connectionGeneration = 0, _selectionEpoch = 0, _localIdCounter = 0;
  bool _polling = false, _foreground = true, _disposed = false;

  bool get paired => api != null;

  /// Unconfirmed sends across the active Hub, including unopened sessions.
  /// Callers open the owning session to reconcile with the server before retrying.
  List<({String sessionId, ChatMessage message})> get unresolvedMessages {
    final rows = <({String sessionId, ChatMessage message})>[];
    for (final entry in (_outbox[hub] ?? const {}).entries) {
      for (final item in entry.value.values) {
        rows.add((sessionId: entry.key, message: _optimisticMessage(item)));
      }
    }
    rows.sort((a, b) => a.message.createdAt.compareTo(b.message.createdAt));
    return List.unmodifiable(rows);
  }

  String draftFor(String sessionId) {
    final currentHub = hub;
    return currentHub == null ? '' : _drafts[currentHub]?[sessionId] ?? '';
  }

  void setDraft(String sessionId, String text) {
    final currentHub = hub;
    if (currentHub == null || _disposed) return;
    final rows = _drafts.putIfAbsent(currentHub, () => {});
    text.isEmpty ? rows.remove(sessionId) : rows[sessionId] = text;
    _draftPersist?.cancel();
    _draftPersist = Timer(const Duration(milliseconds: 300), () {
      _draftPersist = null;
      _persistInBackground();
    });
  }

  Future<void> restore() async {
    if (!_persistState || _disposed) return;
    final generation = ++_connectionGeneration;
    try {
      await _storageTail;
      final raw = await _storage.read(key: _stateKey);
      if (!_connectionIsCurrent(generation) || raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('invalid state');
      final state = decoded.cast<String, dynamic>();
      _decodeState(state);
      final activeHub = state['activeHub'];
      if (activeHub is! String || activeHub.isEmpty) return;
      final token = _credentials[activeHub];
      if (token == null || token.isEmpty) return;
      if (PairingTarget.isLanHttp(PairingTarget.parseHub(activeHub))) {
        pendingLanHub = activeHub;
        _safeNotify();
        return;
      }
      await pair(activeHub, token, persist: false);
    } catch (exception) {
      if (_connectionIsCurrent(generation)) {
        error = '无法恢复本地连接：$exception';
        _safeNotify();
      }
    }
  }

  /// Called only after the user confirms the saved LAN destination in the UI.
  Future<void> reconnectLan() async {
    final target = pendingLanHub;
    final token = _credentials[target];
    if (target == null || token == null) return;
    await pair(target, token, allowLanHttp: true);
  }

  Future<void> pair(
    String rawHub,
    String token, {
    bool persist = true,
    bool allowLanHttp = false,
  }) => _pair(rawHub, token, persist: persist, allowLanHttp: allowLanHttp);

  /// Device credentials live with their certificate pin in the separate secure
  /// registry. Stable identity keeps drafts/outbox intact when DHCP changes IP.
  Future<void> pairVerifiedDevice(HapiApi candidate, String fingerprint) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint))
      throw HubException('无效电脑身份');
    return _pair(
      candidate.baseUrl.toString(),
      candidate.accessToken,
      persist: false,
      verifiedApi: candidate,
      connectionId: 'device:$fingerprint',
    );
  }

  Future<void> _pair(
    String rawHub,
    String token, {
    bool persist = true,
    bool allowLanHttp = false,
    HapiApi? verifiedApi,
    String? connectionId,
  }) async {
    await _flushDraftPersistence();
    final uri = PairingTarget.parseHub(rawHub);
    if (uri.scheme == 'http' && !allowLanHttp) {
      throw HubException('请先确认使用可信局域网 HTTP 连接');
    }
    if (token.trim().isEmpty) throw HubException('访问令牌不能为空');
    final generation = ++_connectionGeneration;
    final candidate = verifiedApi ?? _apiFactory(uri, token.trim());
    loading = true;
    error = null;
    _safeNotify();
    try {
      final health = await candidate.health();
      if (!_connectionIsCurrent(generation)) {
        candidate.close();
        return;
      }
      if (health['status'] != 'ok' || health['protocolVersion'] != 1)
        throw HubException('Hub 协议不兼容');
      await candidate.authenticate();
      if (!_connectionIsCurrent(generation)) {
        candidate.close();
        return;
      }
      final nextHub = connectionId ?? uri.toString();
      pendingLanHub = null;
      if (_persistState && persist) {
        final credentials = Map<String, String>.from(_credentials)
          ..[nextHub] = token.trim();
        await _writeState(
          activeHub: nextHub,
          credentials: credentials,
          drafts: _drafts,
          outbox: _outbox,
        );
        if (!_connectionIsCurrent(generation)) {
          candidate.close();
          return;
        }
        _credentials
          ..clear()
          ..addAll(credentials);
      }
      final previous = api;
      api = candidate;
      hub = nextHub;
      selectedSession = null;
      _selectionEpoch++;
      messages = [];
      requests = [];
      failedSends.clear();
      submittedRequests.clear();
      _resetMessageWindow();
      previous?.close();
      await refresh();
      if (!_connectionIsCurrent(generation) || api != candidate) return;
      _startPolling();
    } catch (exception) {
      candidate.close();
      if (!_connectionIsCurrent(generation)) return;
      final target = uri.toString();
      if (_isTerminalAuth(exception) &&
          _credentials[target] == token.trim() &&
          !(api != null && hub == target)) {
        await _forgetCredential(target);
      }
      error = '$exception';
      rethrow;
    } finally {
      if (_connectionIsCurrent(generation)) {
        loading = false;
        _safeNotify();
      }
    }
  }

  Future<void> pairLink(String text, {bool allowLanHttp = false}) async {
    final target = PairingTarget.parseLink(text);
    await pair(target.uri.toString(), target.code, allowLanHttp: allowLanHttp);
  }

  Future<void> logout() async {
    await _flushDraftPersistence();
    final generation = ++_connectionGeneration;
    _selectionEpoch++;
    _poll?.cancel();
    _poll = null;
    final previous = api, oldHub = hub;
    api = null;
    hub = null;
    selectedSession = null;
    sessions = [];
    messages = [];
    machines = [];
    requests = [];
    failedSends.clear();
    submittedRequests.clear();
    resuming.clear();
    loading = false;
    _resetMessageWindow();
    previous?.close();
    if (oldHub != null) {
      _credentials.remove(oldHub);
      _drafts.remove(oldHub);
      _outbox.remove(oldHub);
    }
    try {
      await _writeCurrentState(activeHub: null);
    } catch (exception) {
      if (_connectionIsCurrent(generation)) error = '无法清除本地连接：$exception';
    }
    if (_connectionIsCurrent(generation)) _safeNotify();
  }

  Future<void> refresh() async {
    final current = api;
    if (current == null || _disposed) return;
    final generation = _connectionGeneration;
    try {
      final values = await Future.wait<Object>([
        current.sessions(),
        current.machines(),
      ]);
      if (!_apiIsCurrent(current, generation)) return;
      sessions = values[0] as List<SessionSummary>;
      machines = values[1] as List<Machine>;
      error = null;
      _safeNotify();
    } catch (exception) {
      await _handleFailure(exception, current, generation);
    }
  }

  Future<void> openSession(String id) async {
    final current = api;
    if (current == null || _disposed) return;
    final generation = _connectionGeneration, epoch = ++_selectionEpoch;
    selectedSession = id;
    messages = _optimisticMessagesFor(id);
    requests = [];
    submittedRequests.clear();
    failedSends
      ..clear()
      ..addAll(_outboxFor(id).keys);
    _resetMessageWindow();
    _safeNotify();
    try {
      final values = await Future.wait<Object>([
        current.messagePageWithCursors(id),
        current.pending(id),
      ]);
      if (!_selectionIsCurrent(current, generation, id, epoch)) return;
      _applyLatestPage(id, values[0] as MessagePage, replaceServerRows: true);
      _applyRequests(values[1] as List<PendingRequest>);
      error = null;
      _safeNotify();
    } catch (exception) {
      await _handleSelectionFailure(exception, current, generation, id, epoch);
    }
  }

  Future<void> loadEarlier() async {
    final current = api, id = selectedSession;
    final beforeSeq = _beforeSeq, beforeAt = _beforeAt;
    final generation = _connectionGeneration, epoch = _selectionEpoch;
    if (current == null ||
        id == null ||
        beforeSeq == null ||
        beforeAt == null ||
        !hasEarlierMessages)
      return;
    try {
      final page = await current.messagePageWithCursors(
        id,
        beforeSeq: beforeSeq,
        beforeAt: beforeAt,
      );
      if (!_selectionIsCurrent(current, generation, id, epoch)) return;
      messages = _mergeMessages(page.messages, messages);
      _beforeSeq = page.beforeSeq;
      _beforeAt = page.beforeAt;
      hasEarlierMessages = page.hasMore;
      _reconcileOutbox(id);
      error = null;
      _safeNotify();
    } catch (exception) {
      await _handleSelectionFailure(exception, current, generation, id, epoch);
    }
  }

  Future<void> refreshOpen() async {
    final current = api, id = selectedSession;
    if (current == null || id == null || _disposed) return;
    final generation = _connectionGeneration, selection = _selectionEpoch;
    try {
      await _catchUpMessages(current, generation, id, selection);
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
      final fresh = await current.pending(id);
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
      _applyRequests(fresh);
      error = null;
      _safeNotify();
    } catch (exception) {
      await _handleSelectionFailure(
        exception,
        current,
        generation,
        id,
        selection,
      );
    }
  }

  Future<void> _catchUpMessages(
    HapiApi current,
    int generation,
    String id,
    int selection,
  ) async {
    if (_afterSeq == null || _afterAt == null || _messageEpoch == null) {
      final page = await current.messagePageWithCursors(id);
      if (_selectionIsCurrent(current, generation, id, selection))
        _applyLatestPage(id, page, replaceServerRows: false);
      return;
    }
    var afterSeq = _afterSeq!, afterAt = _afterAt!;
    int? untilSeq, untilAt;
    for (var count = 0; count < 100; count++) {
      final page = await current.messagePageWithCursors(
        id,
        afterSeq: afterSeq,
        afterAt: afterAt,
        untilSeq: untilSeq,
        untilAt: untilAt,
        epoch: _messageEpoch,
      );
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
      if (page.reset || page.direction == 'latest') {
        _resetMessageWindow();
        _applyLatestPage(id, page, replaceServerRows: true);
        return;
      }
      untilSeq ??= page.snapshotHeadSeq;
      untilAt ??= page.snapshotHeadAt;
      messages = _mergeMessages(messages, page.messages);
      _messageEpoch = page.epoch ?? _messageEpoch;
      final nextSeq = page.afterSeq, nextAt = page.afterAt;
      if (nextSeq != null && nextAt != null) {
        _afterSeq = nextSeq;
        _afterAt = nextAt;
      }
      _reconcileOutbox(id);
      if (!page.hasMore || nextSeq == null || nextAt == null) return;
      if (_comparePosition(nextAt, nextSeq, afterAt, afterSeq) <= 0)
        throw HubException('消息游标没有前进');
      afterSeq = nextSeq;
      afterAt = nextAt;
    }
    throw HubException('消息增量同步页数过多');
  }

  Future<void> send(String text, {String? retryLocalId}) async {
    final current = api, id = selectedSession, currentHub = hub;
    if (current == null || id == null || currentHub == null || _disposed)
      return;
    final value = text.trim();
    if (value.isEmpty) return;
    final generation = _connectionGeneration, selection = _selectionEpoch;
    final sessionOutbox = _outboxFor(id, create: true);
    late final _OutboxItem item;
    if (retryLocalId != null) {
      final existing = sessionOutbox[retryLocalId];
      if (existing == null || existing.text != value) {
        error = '只能使用原消息内容和 localId 重试待发送消息';
        _safeNotify();
        return;
      }
      item = existing;
    } else {
      _draftPersist?.cancel();
      _draftPersist = null;
      final localId = _nextLocalId();
      item = _OutboxItem(
        localId: localId,
        text: value,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      sessionOutbox[localId] = item;
      final draft = _drafts[currentHub]?[id];
      if (draft == text || draft == value) _drafts[currentHub]?.remove(id);
      try {
        await _writeCurrentState(activeHub: currentHub);
      } catch (exception) {
        sessionOutbox.remove(localId);
        // A failed durable write must not consume the editor's only copy.
        if (_apiIsCurrent(current, generation) && draft != null) {
          _drafts
              .putIfAbsent(currentHub, () => {})
              .putIfAbsent(id, () => draft);
        }
        error = '消息未发送：无法安全保存待发送队列（$exception）';
        _safeNotify();
        return;
      }
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
      messages = _mergeMessages(messages, [_optimisticMessage(item)]);
      _safeNotify();
    }
    failedSends.remove(item.localId);
    _safeNotify();
    try {
      await current.send(id, item.text, item.localId);
      if (_selectionIsCurrent(current, generation, id, selection))
        await refreshOpen();
    } catch (exception) {
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
      failedSends.add(item.localId);
      await _handleSelectionFailure(
        exception,
        current,
        generation,
        id,
        selection,
      );
    }
  }

  Future<void> cancelMessage(ChatMessage message) async {
    final current = api, id = selectedSession;
    if (current == null || id == null || _disposed) return;
    final messageId = message.localId.isNotEmpty ? message.localId : message.id;
    if (messageId.isEmpty) return;
    final generation = _connectionGeneration, selection = _selectionEpoch;
    try {
      final result = await current.cancelMessage(id, messageId);
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
      if (result.cancelled) {
        final localId = result.localId ?? message.localId;
        if (localId.isNotEmpty) {
          _outboxFor(id).remove(localId);
          failedSends.remove(localId);
          messages = messages
              .where((row) => row.localId != localId && row.id != message.id)
              .toList();
          await _writeCurrentState(activeHub: hub);
          if (!_selectionIsCurrent(current, generation, id, selection)) return;
        }
      } else if (result.message != null) {
        messages = _mergeMessages(messages, [result.message!]);
        _reconcileOutbox(id);
      }
      if (result.busy) error = '消息正在提交，请稍后再试';
      if (result.invoked) error = '消息已被代理接收，无法取消';
      _safeNotify();
    } catch (exception) {
      await _handleSelectionFailure(
        exception,
        current,
        generation,
        id,
        selection,
      );
    }
  }

  Future<void> decide(
    PendingRequest request,
    bool allow, {
    Map<String, dynamic>? answers,
  }) async {
    final current = api, id = selectedSession;
    if (current == null || id == null || _disposed) return;
    if (request.sessionId.isEmpty || request.sessionId != id) {
      error = '审批请求不属于当前会话';
      _safeNotify();
      return;
    }
    if (submittedRequests.contains(request.id)) return;
    final generation = _connectionGeneration, selection = _selectionEpoch;
    submittedRequests.add(request.id);
    _safeNotify();
    var postAccepted = false;
    try {
      final fresh = await current.pending(id);
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
      _applyRequests(fresh);
      if (!fresh.any((row) => row.id == request.id && row.sessionId == id)) {
        _safeNotify();
        return;
      }
      await current.decide(id, request.id, allow, answers: answers);
      postAccepted = true;
      if (_selectionIsCurrent(current, generation, id, selection))
        await refreshOpen();
    } catch (exception) {
      if (!postAccepted &&
          _selectionIsCurrent(current, generation, id, selection)) {
        submittedRequests.remove(request.id);
      }
      await _handleSelectionFailure(
        exception,
        current,
        generation,
        id,
        selection,
      );
    }
  }

  Future<String?> create(
    String machine,
    String directory, {
    String? agent,
  }) async {
    final current = api;
    if (current == null || _disposed) return null;
    final flavor = agent ?? selectedAgent;
    final generation = _connectionGeneration, selection = _selectionEpoch;
    try {
      final id = await current.spawn(machine, directory, flavor);
      await refresh();
      if (_apiIsCurrent(current, generation) && selection == _selectionEpoch) {
        selectedAgent = flavor;
        await openSession(id);
      }
      return id;
    } catch (exception) {
      await refresh();
      if (!_apiIsCurrent(current, generation)) return null;
      final surfaced = exception is HubException && exception.status == null
          ? HubException('创建结果未确认，请先刷新会话列表：$exception')
          : exception;
      await _handleFailure(surfaced, current, generation);
      throw surfaced;
    }
  }

  void setAgent(String value) {
    final changed = selectedAgent != value;
    selectedAgent = value;
    final id = selectedSession;
    if (id != null) {
      final selected = sessions.where((row) => row.id == id).firstOrNull;
      if (selected == null || selected.flavor != value) closeSession();
    }
    if (changed) _safeNotify();
  }

  void closeSession() {
    _selectionEpoch++;
    selectedSession = null;
    messages = [];
    requests = [];
    failedSends.clear();
    submittedRequests.clear();
    _resetMessageWindow();
    _safeNotify();
  }

  /// 会话权限模式；只记录在 App 内切换过的会话。
  ///
  /// 电脑端的会话列表不返回当前模式，因此这里以本地记录为准；未记录表示沿用
  /// 电脑端默认值。
  final Map<String, String> _permissionModes = {};

  /// 返回指定会话当前生效的权限模式。
  ///
  /// 优先用电脑端上报的值（这才反映真实档位，包括在电脑上改过的），本地记录
  /// 仅作为电脑端尚未上报时的兜底。
  String? permissionModeFor(String sessionId) {
    final reported = sessions
        .where((session) => session.id == sessionId)
        .firstOrNull
        ?.permissionMode;
    return reported ?? _permissionModes[sessionId];
  }

  /// 设置当前会话的权限模式，并记录到本地。
  ///
  /// 目标范围限定在 `selectedSession`：切换会话过程中的响应不会写入新会话。
  ///
  /// @param mode 电脑端认可的权限模式机器值
  Future<void> setPermissionMode(String mode) async {
    final current = api, id = selectedSession;
    if (current == null || id == null || _disposed || mode.isEmpty) return;
    final generation = _connectionGeneration, selection = _selectionEpoch;
    try {
      await current.setPermissionMode(id, mode);
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
      _permissionModes[id] = mode;
      _safeNotify();
      // 拉一次目录，让选项上显示的是电脑端确认后的档位。
      unawaited(refresh());
    } catch (exception) {
      await _handleSelectionFailure(
        exception,
        current,
        generation,
        id,
        selection,
      );
    }
  }

  Future<void> abortSelected() async {
    final current = api, id = selectedSession;
    if (current == null || id == null || _disposed) return;
    final generation = _connectionGeneration, selection = _selectionEpoch;
    try {
      await current.abort(id);
      if (_selectionIsCurrent(current, generation, id, selection))
        await refreshOpen();
    } catch (exception) {
      await _handleSelectionFailure(
        exception,
        current,
        generation,
        id,
        selection,
      );
    }
  }

  Future<void> rename(String value) async {
    final current = api, id = selectedSession;
    if (current == null || id == null || _disposed) return;
    final generation = _connectionGeneration, selection = _selectionEpoch;
    try {
      await current.rename(id, value);
      await refresh();
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
    } catch (exception) {
      await _handleSelectionFailure(
        exception,
        current,
        generation,
        id,
        selection,
      );
    }
  }

  Future<void> resumeSelected() async {
    final current = api, id = selectedSession, currentHub = hub;
    if (current == null || id == null || currentHub == null || _disposed)
      return;
    if (!resuming.add(id)) return;
    _safeNotify();
    final generation = _connectionGeneration, selection = _selectionEpoch;
    try {
      final replacement = await current.resume(id);
      await refresh();
      if (!_selectionIsCurrent(current, generation, id, selection)) return;
      final oldDraft = _drafts[currentHub]?[id];
      if (replacement != id && oldDraft != null && oldDraft.isNotEmpty) {
        final rows = _drafts.putIfAbsent(currentHub, () => {});
        rows.putIfAbsent(replacement, () => oldDraft);
        rows.remove(id);
        await _writeCurrentState(activeHub: currentHub);
        if (!_selectionIsCurrent(current, generation, id, selection)) return;
      }
      await openSession(replacement); // Outbox intentionally remains on id.
    } catch (exception) {
      await _handleSelectionFailure(
        exception,
        current,
        generation,
        id,
        selection,
      );
    } finally {
      resuming.remove(id);
      _safeNotify();
    }
  }

  void _startPolling() {
    _poll?.cancel();
    if (!_foreground || _disposed || api == null) return;
    _poll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollOnce()),
    );
  }

  Future<void> _pollOnce() async {
    if (_polling || !_foreground || !paired || _disposed) return;
    _polling = true;
    try {
      await refresh();
      await refreshOpen();
    } finally {
      _polling = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _startPolling();
      unawaited(_pollOnce());
    } else {
      _poll?.cancel();
      _poll = null;
      unawaited(_flushDraftPersistence());
    }
  }

  void _applyLatestPage(
    String sessionId,
    MessagePage page, {
    required bool replaceServerRows,
  }) {
    final optimistic = _optimisticMessagesFor(sessionId);
    messages = replaceServerRows
        ? _mergeMessages(page.messages, optimistic)
        : _mergeMessages(messages, page.messages, optimistic);
    _beforeSeq = page.beforeSeq ?? _beforeSeq;
    _beforeAt = page.beforeAt ?? _beforeAt;
    hasEarlierMessages =
        page.hasMore || (!replaceServerRows && hasEarlierMessages);
    _messageEpoch = page.epoch ?? _messageEpoch;
    final newest = _newestPosition(page.messages);
    _afterSeq =
        page.afterSeq ?? page.snapshotHeadSeq ?? newest?.$2 ?? _afterSeq;
    _afterAt = page.afterAt ?? page.snapshotHeadAt ?? newest?.$1 ?? _afterAt;
    _reconcileOutbox(sessionId);
  }

  void _applyRequests(List<PendingRequest> fresh) {
    final id = selectedSession;
    requests = id == null
        ? const []
        : fresh.where((row) => row.sessionId == id).toList();
    final authoritative = requests.map((row) => row.id).toSet();
    submittedRequests.removeWhere(
      (requestId) => !authoritative.contains(requestId),
    );
  }

  void _reconcileOutbox(String sessionId) {
    final rows = _outboxFor(sessionId);
    if (rows.isEmpty) return;
    final echoed = messages
        .where((row) => row.localId.isNotEmpty && !row.pending)
        .map((row) => row.localId)
        .toSet();
    var changed = false;
    for (final localId in echoed) {
      changed = rows.remove(localId) != null || changed;
      failedSends.remove(localId);
    }
    if (changed) _persistInBackground();
  }

  List<ChatMessage> _optimisticMessagesFor(String id) =>
      _outboxFor(id).values.map(_optimisticMessage).toList();
  ChatMessage _optimisticMessage(_OutboxItem item) => ChatMessage(
    id: item.localId,
    localId: item.localId,
    role: 'user',
    view: MessageView.user,
    text: item.text,
    createdAt: item.createdAt,
    pending: true,
    hasInvokedAt: true,
  );

  Map<String, _OutboxItem> _outboxFor(String sessionId, {bool create = false}) {
    final currentHub = hub;
    if (currentHub == null) return {};
    if (!create) return _outbox[currentHub]?[sessionId] ?? {};
    return _outbox
        .putIfAbsent(currentHub, () => {})
        .putIfAbsent(sessionId, () => {});
  }

  String _nextLocalId() =>
      'flutter-${DateTime.now().microsecondsSinceEpoch}-${++_localIdCounter}';

  List<ChatMessage> _mergeMessages(
    List<ChatMessage> first,
    List<ChatMessage> second, [
    List<ChatMessage> third = const [],
  ]) {
    final byIdentity = <String, ChatMessage>{};
    for (final row in [...first, ...second, ...third]) {
      final identity = row.localId.isNotEmpty
          ? 'local:${row.localId}'
          : 'id:${row.id}';
      final existing = byIdentity[identity];
      if (existing == null || _messageIsNewer(row, existing))
        byIdentity[identity] = row;
    }
    final byStream = <String, ChatMessage>{}, plain = <ChatMessage>[];
    for (final row in byIdentity.values) {
      final stream = row.streamId;
      if (stream == null || stream.isEmpty) {
        plain.add(row);
        continue;
      }
      final existing = byStream[stream];
      if (existing == null || _messageIsNewer(row, existing))
        byStream[stream] = row;
    }
    final merged = [...plain, ...byStream.values];
    merged.sort((left, right) {
      final at = (left.invokedAt ?? left.createdAt).compareTo(
        right.invokedAt ?? right.createdAt,
      );
      if (at != 0) return at;
      final seq = (left.seq ?? 0).compareTo(right.seq ?? 0);
      return seq != 0 ? seq : left.id.compareTo(right.id);
    });
    return merged;
  }

  bool _messageIsNewer(ChatMessage candidate, ChatMessage existing) {
    if (existing.pending != candidate.pending) return !candidate.pending;
    return _comparePosition(
          candidate.invokedAt ?? candidate.createdAt,
          candidate.seq ?? 0,
          existing.invokedAt ?? existing.createdAt,
          existing.seq ?? 0,
        ) >=
        0;
  }

  (int, int)? _newestPosition(List<ChatMessage> rows) {
    ChatMessage? newest;
    for (final row in rows) {
      if (row.seq != null && (newest == null || _messageIsNewer(row, newest)))
        newest = row;
    }
    return newest == null
        ? null
        : (newest.invokedAt ?? newest.createdAt, newest.seq!);
  }

  int _comparePosition(int leftAt, int leftSeq, int rightAt, int rightSeq) {
    final at = leftAt.compareTo(rightAt);
    return at != 0 ? at : leftSeq.compareTo(rightSeq);
  }

  void _resetMessageWindow() {
    _beforeSeq = null;
    _beforeAt = null;
    _afterSeq = null;
    _afterAt = null;
    _messageEpoch = null;
    hasEarlierMessages = false;
  }

  bool _connectionIsCurrent(int generation) =>
      !_disposed && generation == _connectionGeneration;
  bool _apiIsCurrent(HapiApi candidate, int generation) =>
      _connectionIsCurrent(generation) && identical(api, candidate);
  bool _selectionIsCurrent(
    HapiApi candidate,
    int generation,
    String id,
    int selection,
  ) =>
      _apiIsCurrent(candidate, generation) &&
      selection == _selectionEpoch &&
      selectedSession == id;
  bool _isTerminalAuth(Object exception) =>
      exception is ApiException && exception.terminalAuth;

  Future<void> _handleFailure(
    Object exception,
    HapiApi candidate,
    int generation,
  ) async {
    if (!_apiIsCurrent(candidate, generation)) return;
    if (_isTerminalAuth(exception)) {
      await _terminalUnpair(candidate, generation);
      return;
    }
    error = '$exception';
    _safeNotify();
  }

  Future<void> _handleSelectionFailure(
    Object exception,
    HapiApi candidate,
    int generation,
    String id,
    int selection,
  ) async {
    if (_selectionIsCurrent(candidate, generation, id, selection))
      await _handleFailure(exception, candidate, generation);
  }

  Future<void> _terminalUnpair(HapiApi candidate, int generation) async {
    if (!_apiIsCurrent(candidate, generation)) return;
    final oldHub = hub;
    _connectionGeneration++;
    final unpairGeneration = _connectionGeneration;
    _selectionEpoch++;
    _poll?.cancel();
    _poll = null;
    _draftPersist?.cancel();
    _draftPersist = null;
    api = null;
    hub = null;
    selectedSession = null;
    sessions = [];
    machines = [];
    messages = [];
    requests = [];
    failedSends.clear();
    submittedRequests.clear();
    resuming.clear();
    loading = false;
    _resetMessageWindow();
    candidate.close();
    if (oldHub != null) {
      // Revocation invalidates credentials, not the user's unsent work.
      _credentials.remove(oldHub);
      try {
        await _writeCurrentState(activeHub: null);
      } catch (_) {}
    }
    if (!_connectionIsCurrent(unpairGeneration)) return;
    error = '认证已失效，请重新配对';
    _safeNotify();
  }

  Future<void> _forgetCredential(String targetHub) async {
    _credentials.remove(targetHub);
    try {
      await _writeCurrentState(activeHub: hub == targetHub ? null : hub);
    } catch (_) {}
  }

  void _persistInBackground() {
    if (!_persistState || _disposed) return;
    unawaited(
      _writeCurrentState(activeHub: hub).catchError((Object exception) {
        if (!_disposed) {
          error = '无法保存本地状态：$exception';
          _safeNotify();
        }
      }),
    );
  }

  Future<void> _flushDraftPersistence() async {
    if (_draftPersist == null) return;
    _draftPersist?.cancel();
    _draftPersist = null;
    await _writeCurrentState(activeHub: hub);
  }

  Future<void> _writeCurrentState({required String? activeHub}) => _writeState(
    activeHub: activeHub,
    credentials: _credentials,
    drafts: _drafts,
    outbox: _outbox,
  );
  Future<void> _writeState({
    required String? activeHub,
    required Map<String, String> credentials,
    required Map<String, Map<String, String>> drafts,
    required Map<String, Map<String, Map<String, _OutboxItem>>> outbox,
  }) {
    if (!_persistState) return Future.value();
    final connections = <String, dynamic>{};
    for (final key in {...credentials.keys, ...drafts.keys, ...outbox.keys}) {
      connections[key] = {
        'token': credentials[key],
        'drafts': drafts[key] ?? const <String, String>{},
        'outbox': (outbox[key] ?? const <String, Map<String, _OutboxItem>>{})
            .map(
              (session, rows) => MapEntry(
                session,
                rows.map((id, item) => MapEntry(id, item.toJson())),
              ),
            ),
      };
    }
    final encoded = jsonEncode({
      'version': _stateVersion,
      'activeHub': activeHub,
      'connections': connections,
    });
    final operation = _storageTail.then(
      (_) => _storage.write(key: _stateKey, value: encoded),
    );
    _storageTail = operation.catchError((_) {});
    return operation;
  }

  void _decodeState(Map<String, dynamic> state) {
    if (state['version'] != _stateVersion || state['connections'] is! Map)
      return;
    _credentials.clear();
    _drafts.clear();
    _outbox.clear();
    for (final entry in (state['connections'] as Map).entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final hubKey = entry.key as String,
          row = (entry.value as Map).cast<String, dynamic>();
      final token = row['token'];
      if (token is String && token.isNotEmpty) _credentials[hubKey] = token;
      if (row['drafts'] is Map) {
        _drafts[hubKey] = {
          for (final draft in (row['drafts'] as Map).entries)
            if (draft.key is String && draft.value is String)
              draft.key as String: draft.value as String,
        };
      }
      if (row['outbox'] is! Map) continue;
      final hubRows = <String, Map<String, _OutboxItem>>{};
      for (final session in (row['outbox'] as Map).entries) {
        if (session.key is! String || session.value is! Map) continue;
        final values = <String, _OutboxItem>{};
        for (final raw in (session.value as Map).values) {
          final item = _OutboxItem.fromJson(raw);
          if (item != null) values[item.localId] = item;
        }
        if (values.isNotEmpty) hubRows[session.key as String] = values;
      }
      if (hubRows.isNotEmpty) _outbox[hubKey] = hubRows;
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (_draftPersist != null) {
      _draftPersist?.cancel();
      _draftPersist = null;
      _persistInBackground();
    }
    _disposed = true;
    _connectionGeneration++;
    _selectionEpoch++;
    _poll?.cancel();
    _poll = null;
    WidgetsBinding.instance.removeObserver(this);
    final previous = api;
    api = null;
    previous?.close();
    super.dispose();
  }
}
