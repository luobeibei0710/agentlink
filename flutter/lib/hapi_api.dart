import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'domain.dart';
import 'connection_policy.dart';

abstract class HapiTransport {
  Future<http.Response> send(http.Request request);
  void close();
}

class HttpTransport implements HapiTransport {
  HttpTransport(this._client);
  final http.Client _client;
  @override
  Future<http.Response> send(http.Request r) =>
      _client.send(r).then(http.Response.fromStream);
  @override
  void close() => _client.close();
}

class HapiApi {
  HapiApi(this.baseUrl, this.accessToken, {HapiTransport? transport})
    : _transport = transport ?? HttpTransport(http.Client());
  final Uri baseUrl;
  final String accessToken;
  final HapiTransport _transport;
  String? _jwt;
  Future<void>? _refreshing;
  void close() => _transport.close();
  Uri _uri(String path, [Map<String, String>? query]) =>
      baseUrl.replace(path: path, queryParameters: query);
  Future<Map<String, dynamic>> health() => _json('GET', '/health', auth: false);
  Future<void> authenticate() async {
    final r = await _json(
      'POST',
      '/api/auth',
      auth: false,
      body: {'accessToken': accessToken},
    );
    final token = r['token'];
    if (token is! String || token.trim().isEmpty)
      throw HubException('Hub 返回了无效认证令牌');
    _jwt = token;
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool auth = true,
    bool retry = true,
    Duration? timeout,
  }) async {
    PairingTarget.parseHub(baseUrl.toString());
    if (auth && _jwt == null) await _refresh();
    final token = _jwt;
    final req = http.Request(method, _uri(path, query));
    // Never forward credentials through a redirect, especially an HTTP QR target.
    req.followRedirects = false;
    req.headers['accept'] = 'application/json';
    if (auth) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response response;
    try {
      response = await _transport
          .send(req)
          .timeout(timeout ?? const Duration(seconds: 30));
    } on HubException {
      rethrow;
    } on TimeoutException {
      throw HubException('网络请求超时');
    } catch (e) {
      throw HubException('网络错误：$e');
    }
    final decoded = _decode(response.body);
    if (response.statusCode == 401 && auth && retry) {
      if (_jwt == token) await _refresh(force: true);
      return _json(
        method,
        path,
        body: body,
        query: query,
        retry: false,
        timeout: timeout,
      );
    }
    if (response.statusCode == 401) {
      _jwt = null;
      throw ApiException(
        '${decoded['error'] ?? decoded['message'] ?? '认证已失效'}',
        status: 401,
        terminalAuth: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw ApiException(
        '${decoded['error'] ?? decoded['message'] ?? '请求失败 (${response.statusCode})'}',
        status: response.statusCode,
      );
    if (decoded['success'] == false)
      throw ApiException(
        '${decoded['error'] ?? decoded['message'] ?? 'Hub 拒绝了请求'}',
        status: response.statusCode,
      );
    return decoded;
  }

  Map<String, dynamic> _decode(String body) {
    if (body.trim().isEmpty) return <String, dynamic>{};
    try {
      final v = jsonDecode(body);
      return v is Map ? v.cast<String, dynamic>() : {'value': v};
    } catch (_) {
      return {'error': body.length > 300 ? body.substring(0, 300) : body};
    }
  }

  Future<void> _refresh({bool force = false}) async {
    if (_jwt != null && !force) return;
    _refreshing ??= authenticate();
    try {
      await _refreshing;
    } finally {
      _refreshing = null;
    }
  }

  Future<List<SessionSummary>> sessions() async {
    final r = await _json(
      'GET',
      '/api/sessions',
      query: {'order': 'updatedAt'},
    );
    return ((r['sessions'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => SessionSummary.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<List<Machine>> machines() async {
    final r = await _json('GET', '/api/machines');
    return ((r['machines'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Machine.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<List<AgentAvailability>> agentAvailability(String machineId) async {
    final r = await _json(
      'GET',
      '/api/machines/${Uri.encodeComponent(machineId)}/agent-availability',
    );
    return ((r['agents'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => AgentAvailability.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<bool> machineCanRun(String machineId, String agent) async =>
      (await agentAvailability(
        machineId,
      )).any((e) => e.agent == agent && e.available);
  Future<List<ChatMessage>> messages(
    String id, {
    int? beforeSeq,
    int? beforeAt,
    int? afterSeq,
    int? afterAt,
    int? untilSeq,
    int? untilAt,
    int? epoch,
  }) async => (await messagePageWithCursors(
    id,
    beforeSeq: beforeSeq,
    beforeAt: beforeAt,
    afterSeq: afterSeq,
    afterAt: afterAt,
    untilSeq: untilSeq,
    untilAt: untilAt,
    epoch: epoch,
  )).messages;
  Future<MessagePage> messagePage(String id, {int? beforeSeq, int? beforeAt}) =>
      messagePageWithCursors(id, beforeSeq: beforeSeq, beforeAt: beforeAt);

  Future<MessagePage> messagePageWithCursors(
    String id, {
    int? beforeSeq,
    int? beforeAt,
    int? afterSeq,
    int? afterAt,
    int? untilSeq,
    int? untilAt,
    int? epoch,
  }) async {
    final q = <String, String>{'limit': '50'};
    void pair(String a, int? x, String b, int? y) {
      if (x != null && y != null) {
        q[a] = '$x';
        q[b] = '$y';
      }
    }

    pair('beforeSeq', beforeSeq, 'beforeAt', beforeAt);
    pair('afterSeq', afterSeq, 'afterAt', afterAt);
    pair('untilSeq', untilSeq, 'untilAt', untilAt);
    if (epoch != null) q['epoch'] = '$epoch';
    final r = await _json(
      'GET',
      '/api/sessions/${Uri.encodeComponent(id)}/messages',
      query: q,
    );
    final p = (r['page'] as Map?)?.cast<String, dynamic>() ?? const {};
    return MessagePage(
      messages: ((r['messages'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => ChatMessage.fromJson(e.cast<String, dynamic>()))
          .toList(),
      hasMore: p['hasMore'] == true,
      beforeSeq: _number(p['nextBeforeSeq']),
      beforeAt: _number(p['nextBeforeAt']),
      afterSeq: _number(p['nextAfterSeq']),
      afterAt: _number(p['nextAfterAt']),
      snapshotHeadSeq: _number(p['snapshotHeadSeq']),
      snapshotHeadAt: _number(p['snapshotHeadAt']),
      epoch: _number(p['epoch']),
      reset: p['reset'] == true,
      direction: p['direction'] as String?,
    );
  }

  Future<List<PendingRequest>> pending(String id) async {
    final r = await _json('GET', '/api/sessions/${Uri.encodeComponent(id)}');
    final s = (r['session'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (s['active'] != true) return const [];
    final requests =
        ((s['agentState'] as Map?)?.cast<String, dynamic>() ??
        const {})['requests'];
    if (requests is! Map) return const [];
    return requests.entries
        .where((e) => e.key is String && e.value is Map)
        .map(
          (e) => PendingRequest.fromEntry(
            id,
            e.key as String,
            (e.value as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
  }

  Future<void> rename(String id, String name) async => _json(
    'PATCH',
    '/api/sessions/${Uri.encodeComponent(id)}',
    body: {'name': name},
  );
  Future<void> send(String id, String text, String localId) async => _json(
    'POST',
    '/api/sessions/${Uri.encodeComponent(id)}/messages',
    body: {'text': text, 'localId': localId},
  );
  Future<void> cancel(String s, String m) async => _json(
    'DELETE',
    '/api/sessions/${Uri.encodeComponent(s)}/messages/${Uri.encodeComponent(m)}',
  );
  Future<void> abort(String id) async =>
      _json('POST', '/api/sessions/${Uri.encodeComponent(id)}/abort', body: {});

  /// 设置会话的权限模式（默认每次确认 / 只读 / 全自动 等）。
  Future<void> setPermissionMode(String id, String mode) async => _json(
    'POST',
    '/api/sessions/${Uri.encodeComponent(id)}/permission-mode',
    body: {'mode': mode},
  );
  Future<String> resume(String id) async {
    final r = await _json(
      'POST',
      '/api/sessions/${Uri.encodeComponent(id)}/resume',
      body: {},
    );
    return _requiredSessionId(r, '恢复会话');
  }

  Future<void> decide(
    String s,
    String r,
    bool allow, {
    Map<String, dynamic>? answers,
  }) async {
    await _json(
      'POST',
      '/api/sessions/${Uri.encodeComponent(s)}/permissions/${Uri.encodeComponent(r)}/${allow ? 'approve' : 'deny'}',
      body: {'decision': allow ? 'approved' : 'denied', 'answers': ?answers},
    );
  }

  Future<String> spawn(String machine, String directory, String agent) async {
    final r = await _json(
      'POST',
      '/api/machines/${Uri.encodeComponent(machine)}/spawn',
      body: {'directory': directory, 'agent': agent},
      timeout: const Duration(seconds: 95),
    );
    if (r['type'] != 'success')
      throw HubException('${r['message'] ?? '创建会话失败'}');
    return _requiredSessionId(r, '创建会话');
  }

  Future<CancellationResult> cancelMessage(
    String sessionId,
    String messageId,
  ) async {
    final r = await _json(
      'DELETE',
      '/api/sessions/${Uri.encodeComponent(sessionId)}/messages/${Uri.encodeComponent(messageId)}',
    );
    return CancellationResult.fromJson(r);
  }
}

class ApiException extends HubException {
  ApiException(super.message, {super.status, this.terminalAuth = false});
  final bool terminalAuth;
}

class CancellationResult {
  const CancellationResult({required this.status, this.localId, this.message});
  final String status;
  final String? localId;
  final ChatMessage? message;
  factory CancellationResult.fromJson(Map<String, dynamic> json) =>
      CancellationResult(
        status: '${json['status'] ?? 'unknown'}',
        localId: json['localId'] as String?,
        message: json['message'] is Map
            ? ChatMessage.fromJson(
                (json['message'] as Map).cast<String, dynamic>(),
              )
            : null,
      );
  bool get cancelled => status == 'cancelled';
  bool get invoked => status == 'invoked';
  bool get busy => status == 'busy';
}

String _requiredSessionId(Map<String, dynamic> response, String action) {
  final id = response['sessionId'];
  if (id is! String || id.trim().isEmpty)
    throw HubException('$action未返回有效 sessionId');
  return id;
}

int? _number(Object? v) => v is num ? v.toInt() : int.tryParse('$v');
