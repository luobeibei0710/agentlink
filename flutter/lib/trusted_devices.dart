import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'connection_policy.dart';
import 'device_discovery.dart';
import 'domain.dart';
import 'hapi_api.dart';

bool validDeviceSecret(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);
bool validFingerprint(String value) =>
    RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
String commitmentFor(String pin, String serverNonce, String requestId) => sha256
    .convert(utf8.encode('agentlink-commit-v1\n$pin\n$serverNonce\n$requestId'))
    .toString();
String pairingDigits(
  String pin,
  String serverNonce,
  String clientNonce,
  String requestId,
) {
  final hash = sha256
      .convert(
        utf8.encode(
          'agentlink-pair-v1\n$pin\n$serverNonce\n$clientNonce\n$requestId',
        ),
      )
      .toString();
  return (int.parse(hash.substring(0, 8), radix: 16) % 100000000)
      .toString()
      .padLeft(8, '0');
}

class TrustedComputer {
  const TrustedComputer({
    required this.hostId,
    required this.name,
    required this.uri,
    required this.deviceId,
    required this.token,
  });
  final String hostId, name, deviceId, token;
  final Uri uri;
  Map<String, dynamic> toJson() => {
    'hostId': hostId,
    'name': name,
    'uri': uri.toString(),
    'deviceId': deviceId,
    'token': token,
  };
  TrustedComputer at(Uri endpoint) => TrustedComputer(
    hostId: hostId,
    name: name,
    uri: endpoint,
    deviceId: deviceId,
    token: token,
  );
  static TrustedComputer fromJson(Map<String, dynamic> row) {
    final uri = PairingTarget.parseHub(row['uri'] as String);
    final id = row['hostId'] as String, token = row['token'] as String;
    if (uri.scheme != 'https' ||
        !PairingTarget.isLanHttp(uri.replace(scheme: 'http')) ||
        !validFingerprint(id) ||
        !validDeviceSecret(token))
      throw const FormatException('Invalid device record');
    return TrustedComputer(
      hostId: id,
      name: row['name'] as String,
      uri: uri,
      deviceId: row['deviceId'] as String,
      token: token,
    );
  }
}

class TrustedDeviceRegistry {
  TrustedDeviceRegistry({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  final Map<String, TrustedComputer> _devices = {};
  static Future<void>? _tail;
  List<TrustedComputer> get computers => List.unmodifiable(_devices.values);
  Future<void> load() async {
    await _tail;
    final raw = await _storage.read(key: 'agentlink.trusted-devices.v1');
    if (raw == null) return;
    final rows = jsonDecode(raw) as List;
    final loaded = {
      for (final row in rows)
        (row as Map)['hostId'] as String: TrustedComputer.fromJson(
          row.cast<String, dynamic>(),
        ),
    };
    _devices
      ..clear()
      ..addAll(loaded);
  }

  Future<void> save(TrustedComputer computer) =>
      _update(computer.hostId, computer);
  Future<void> forget(String id) => _update(id, null);
  Future<void> _update(String id, TrustedComputer? computer) {
    final operation = (_tail ?? Future<void>.value()).then((_) async {
      final latest = await _storage.read(key: 'agentlink.trusted-devices.v1');
      final next = latest == null
          ? <String, TrustedComputer>{}
          : {
              for (final row in jsonDecode(latest) as List)
                (row as Map)['hostId'] as String: TrustedComputer.fromJson(
                  row.cast<String, dynamic>(),
                ),
            };
      computer == null ? next.remove(id) : next[id] = computer;
      await _storage.write(
        key: 'agentlink.trusted-devices.v1',
        value: jsonEncode(next.values.map((e) => e.toJson()).toList()),
      );
      _devices
        ..clear()
        ..addAll(next);
    });
    final settled = operation.catchError((_) {});
    _tail = settled;
    unawaited(
      settled.then((_) {
        if (identical(_tail, settled)) _tail = null;
      }),
    );
    return operation;
  }
}

/// Uses an empty trust store: even a publicly trusted but different certificate
/// must match the saved pin before any device credential can leave the phone.
class PinnedDeviceTransport implements HapiTransport {
  PinnedDeviceTransport(this.origin, String fingerprint, {this.deviceToken}) {
    if (!validFingerprint(fingerprint) ||
        origin.scheme != 'https' ||
        !PairingTarget.isLanHttp(origin.replace(scheme: 'http')))
      throw HubException('无效的已验证电脑地址');
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (cert, host, port) =>
        host == origin.host &&
        port == origin.port &&
        sha256.convert(cert.der).toString() == fingerprint;
    _client = IOClient(client);
  }
  final Uri origin;
  final String? deviceToken;
  late final http.Client _client;
  @override
  Future<http.Response> send(http.Request request) async {
    if (request.url.origin != origin.origin)
      throw HubException('禁止将设备凭据发送到其他电脑');
    if (deviceToken == null && !request.url.path.startsWith('/link/'))
      throw HubException('首次配对通道不能访问工作台');
    request.followRedirects = false;
    if (deviceToken != null)
      request.headers['x-agentlink-device-token'] = deviceToken!;
    final response = await _client.send(request);
    final maximum = deviceToken == null ? 65536 : 16 * 1024 * 1024;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maximum)
        throw HubException('电脑响应超过允许大小');
      bytes.add(chunk);
    }
    return http.Response.bytes(
      bytes.takeBytes(),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }

  @override
  void close() => _client.close();
}

class PendingDevicePair {
  PendingDevicePair({
    required this.computer,
    required this.transport,
    required this.requestId,
    required this.clientNonce,
    required this.digits,
    required this.expiresAt,
  });
  final NearbyComputer computer;
  final PinnedDeviceTransport transport;
  final String requestId, clientNonce, digits;
  final DateTime expiresAt;
  void close() => transport.close();
}

class DevicePairingService {
  DevicePairingService({this.deviceName = 'AgentLink Android'});
  final String deviceName;
  Future<Map<String, dynamic>> _request(
    PinnedDeviceTransport transport,
    String path,
    Map<String, dynamic> body,
  ) async {
    final request = http.Request('POST', transport.origin.replace(path: path));
    request.headers['content-type'] = 'application/json';
    request.body = jsonEncode(body);
    final response = await transport
        .send(request)
        .timeout(const Duration(seconds: 10));
    if (response.bodyBytes.length > 65536) throw HubException('电脑返回了过大的配对响应');
    final data = jsonDecode(response.body);
    if (data is! Map) throw HubException('无效的配对响应');
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw HubException('配对失败：${data['error'] ?? response.statusCode}');
    return data.cast<String, dynamic>();
  }

  Future<PendingDevicePair> begin(NearbyComputer computer) async {
    // No credentials are sent during the initial TLS observation. Subsequent
    // pairing traffic is pinned to this exact certificate, with SAS verified
    // independently against the physical PC before trust is persisted.
    final socket = await SecureSocket.connect(
      computer.uri.host,
      computer.uri.port,
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: (_) => true,
      timeout: const Duration(seconds: 8),
    );
    final certificate = socket.peerCertificate;
    socket.destroy();
    if (certificate == null ||
        sha256.convert(certificate.der).toString() != computer.hostId)
      throw HubException('电脑身份与发现结果不一致，请重新搜索');
    final transport = PinnedDeviceTransport(computer.uri, computer.hostId);
    try {
      final challenge = await _request(transport, '/link/challenge', {});
      final id = challenge['requestId'], commitment = challenge['commitment'];
      if (id is! String ||
          !validDeviceSecret(id) ||
          commitment is! String ||
          !validFingerprint(commitment))
        throw HubException('无效的电脑身份挑战');
      // Generate only after the server commits to its nonce.
      final nonce = deviceNonce();
      final response = await _request(transport, '/link/requests', {
        'requestId': id,
        'clientNonce': nonce,
        'deviceName': deviceName,
      });
      final serverNonce = response['serverNonce'],
          expires = response['expiresAt'];
      if (serverNonce is! String ||
          !validDeviceSecret(serverNonce) ||
          commitmentFor(computer.hostId, serverNonce, id) != commitment ||
          expires is! num)
        throw HubException('电脑身份确认校验失败');
      final expiry = DateTime.fromMillisecondsSinceEpoch(expires.toInt());
      if (!expiry.isAfter(DateTime.now()) ||
          expiry.difference(DateTime.now()) > const Duration(minutes: 3))
        throw HubException('配对请求已过期');
      return PendingDevicePair(
        computer: computer,
        transport: transport,
        requestId: id,
        clientNonce: nonce,
        digits: pairingDigits(computer.hostId, serverNonce, nonce, id),
        expiresAt: expiry,
      );
    } catch (_) {
      transport.close();
      rethrow;
    }
  }

  Future<TrustedComputer?> poll(PendingDevicePair pair) async {
    if (!pair.expiresAt.isAfter(DateTime.now()))
      throw HubException('配对已超时，请重新发起');
    final response = await _request(
      pair.transport,
      '/link/requests/${pair.requestId}/poll',
      {'clientNonce': pair.clientNonce},
    );
    if (response['status'] == 'pending') return null;
    if (response['status'] != 'approved')
      throw HubException(
        response['status'] == 'denied' ? '电脑拒绝了本次连接' : '配对已失效，请重新发起',
      );
    final token = response['deviceToken'], id = response['deviceId'];
    if (token is! String ||
        !validDeviceSecret(token) ||
        id is! String ||
        id.isEmpty)
      throw HubException('电脑返回了无效设备凭据');
    return TrustedComputer(
      hostId: pair.computer.hostId,
      name: pair.computer.name,
      uri: pair.computer.uri,
      deviceId: id,
      token: token,
    );
  }

  HapiApi api(TrustedComputer computer) => HapiApi(
    computer.uri,
    computer.token,
    transport: PinnedDeviceTransport(
      computer.uri,
      computer.hostId,
      deviceToken: computer.token,
    ),
  );

  Future<void> cancel(PendingDevicePair pair) async {
    final transport = PinnedDeviceTransport(
      pair.computer.uri,
      pair.computer.hostId,
    );
    try {
      await _request(transport, '/link/requests/${pair.requestId}/cancel', {
        'clientNonce': pair.clientNonce,
      });
    } finally {
      transport.close();
    }
  }
}
