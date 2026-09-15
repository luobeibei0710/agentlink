import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'connection_policy.dart';

String deviceNonce() => base64UrlEncode(
  List<int>.generate(32, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');

/// Discovery is an address hint, never proof of a computer's identity.
class NearbyComputer {
  const NearbyComputer({
    required this.name,
    required this.hostId,
    required this.uri,
  });
  final String name;
  final String hostId;
  final Uri uri;

  static NearbyComputer? fromPacket(
    Object? value,
    String nonce,
    String source,
  ) {
    if (value is! Map ||
        value['protocol'] != 'agentlink-discovery-v1' ||
        value['nonce'] != nonce)
      return null;
    final name = value['name'], id = value['hostId'], port = value['port'];
    if (name is! String ||
        name.isEmpty ||
        name.length > 80 ||
        id is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        port is! int ||
        port < 1 ||
        port > 65535)
      return null;
    if (!PairingTarget.isLanHttp(Uri(scheme: 'http', host: source)))
      return null;
    return NearbyComputer(
      name: name,
      hostId: id,
      uri: Uri(scheme: 'https', host: source, port: port),
    );
  }
}

class DeviceDiscovery {
  RawDatagramSocket? _socket;
  bool _closed = false;

  Future<void> scan(
    void Function(NearbyComputer) onComputer, {
    Duration duration = const Duration(seconds: 6),
  }) async {
    final nonce = deviceNonce();
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    if (_closed) {
      socket.close();
      return;
    }
    _socket = socket;
    socket.broadcastEnabled = true;
    final message = utf8.encode(
      jsonEncode({'protocol': 'agentlink-discovery-v1', 'nonce': nonce}),
    );
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        if (_closed || packet!.data.length > 2048) continue;
        try {
          final computer = NearbyComputer.fromPacket(
            jsonDecode(utf8.decode(packet.data)),
            nonce,
            packet.address.address,
          );
          if (computer != null) onComputer(computer);
        } catch (_) {
          /* Ignore unrelated LAN traffic. */
        }
      }
    });
    void announce() {
      if (!_closed)
        socket.send(message, InternetAddress('255.255.255.255'), 3108);
    }

    final timer = Timer.periodic(const Duration(seconds: 1), (_) => announce());
    try {
      announce();
      await Future<void>.delayed(duration);
    } finally {
      timer.cancel();
      await sub.cancel();
      socket.close();
      if (_socket == socket) _socket = null;
    }
  }

  void close() {
    _closed = true;
    _socket?.close();
  }
}
