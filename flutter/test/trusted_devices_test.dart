import 'dart:convert';
import 'dart:io';

import 'package:companion/app_model.dart';
import 'package:companion/connection_policy.dart';
import 'package:companion/device_discovery.dart';
import 'package:companion/hapi_api.dart';
import 'package:companion/trusted_devices.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'app_model_test.dart' show FakeApi, MemoryStorage;

class RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pin = 'a' * 64;
  test(
    'discovery uses source IP and current nonce, never advertised address',
    () {
      final packet = {
        'protocol': 'agentlink-discovery-v1',
        'nonce': 'fresh',
        'hostId': pin,
        'name': 'My PC',
        'port': 3107,
        'address': '8.8.8.8',
      };
      expect(
        NearbyComputer.fromPacket(packet, 'fresh', '192.168.1.2')!.uri.host,
        '192.168.1.2',
      );
      expect(NearbyComputer.fromPacket(packet, 'old', '192.168.1.2'), isNull);
      expect(NearbyComputer.fromPacket(packet, 'fresh', '8.8.8.8'), isNull);
      expect(
        NearbyComputer.fromPacket(
          {...packet, 'port': 0},
          'fresh',
          '192.168.1.2',
        ),
        isNull,
      );
    },
  );
  test('cross-language commitment and SAS transcript vector', () {
    expect(
      commitmentFor(pin, 'B' * 43, 'D' * 43),
      'b752aa80100af5030716c520cb20b62ed98a3f5242478b92fae44eabf27a51b1',
    );
    expect(pairingDigits(pin, 'B' * 43, 'C' * 43, 'D' * 43), '88480188');
    expect(
      pairingDigits('b' * 64, 'B' * 43, 'C' * 43, 'D' * 43),
      isNot('88480188'),
    );
  });
  test('registry changes persist atomically and survives reopening', () async {
    final storage = MemoryStorage(),
        registry = TrustedDeviceRegistry(storage: MemoryStorage());
    final real = TrustedDeviceRegistry(storage: storage);
    final computer = TrustedComputer(
      hostId: pin,
      name: 'PC',
      uri: Uri.parse('https://192.168.1.2:3107'),
      deviceId: 'd',
      token: 'T' * 43,
    );
    await real.save(computer);
    final restored = TrustedDeviceRegistry(storage: storage);
    await restored.load();
    expect(restored.computers.single.hostId, pin);
    storage.failWrites = true;
    await expectLater(restored.forget(pin), throwsA(anything));
    expect(restored.computers, hasLength(1));
    expect(registry.computers, isEmpty);
  });
  test(
    'verified device identity keeps draft across DHCP and never restores unpinned',
    () async {
      final storage = MemoryStorage();
      final model = AppModel(storage: storage);
      await model.pairVerifiedDevice(
        FakeApi(hub: Uri.parse('https://192.168.1.2:3107')),
        pin,
      );
      model.setDraft('a', 'keep this draft');
      await model.pairVerifiedDevice(
        FakeApi(hub: Uri.parse('https://192.168.1.9:3107')),
        pin,
      );
      expect(model.hub, 'device:$pin');
      expect(model.draftFor('a'), 'keep this draft');
      model.dispose();
      var requests = 0;
      final restored = AppModel(
        storage: storage,
        apiFactory: (u, t) {
          requests++;
          return FakeApi();
        },
      );
      await restored.restore();
      expect(requests, 0);
      expect(restored.paired, isFalse);
      expect(storage.values.values.join(), isNot(contains('test-token')));
      restored.dispose();
    },
  );
  test(
    'two registry instances serialize against the latest stored records',
    () async {
      final storage = MemoryStorage();
      final one = TrustedDeviceRegistry(storage: storage),
          two = TrustedDeviceRegistry(storage: storage);
      final a = TrustedComputer(
        hostId: 'a' * 64,
        name: 'A',
        uri: Uri.parse('https://192.168.1.2:3107'),
        deviceId: 'a',
        token: 'A' * 43,
      );
      final b = TrustedComputer(
        hostId: 'b' * 64,
        name: 'B',
        uri: Uri.parse('https://192.168.1.3:3107'),
        deviceId: 'b',
        token: 'B' * 43,
      );
      await Future.wait([one.save(a), two.save(b)]);
      await one.load();
      expect(one.computers, hasLength(2));
      await Future.wait([
        one.forget(a.hostId),
        two.save(b.at(Uri.parse('https://192.168.1.4:3107'))),
      ]);
      await one.load();
      expect(one.computers.single.hostId, b.hostId);
      expect(one.computers.single.uri.host, '192.168.1.4');
    },
  );
  test(
    'actual TLS wrong pin sends no credential; correct pin adds device token',
    () async {
      final addresses =
          (await NetworkInterface.list(type: InternetAddressType.IPv4))
              .expand((i) => i.addresses)
              .where(
                (a) => PairingTarget.isLanHttp(
                  Uri(scheme: 'http', host: a.address),
                ),
              )
              .toList();
      if (addresses.isEmpty)
        return; // Real-LAN integration is also checked separately.
      final directory = await Directory.systemTemp.createTemp(
        'agentlink-pin-test-',
      );
      final key = '${directory.path}/key.pem',
          cert = '${directory.path}/cert.pem';
      final generated = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        key,
        '-out',
        cert,
        '-days',
        '1',
        '-subj',
        '/CN=AgentLink Test',
      ]);
      expect(generated.exitCode, 0);
      final context = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key);
      final server = await HttpServer.bindSecure(addresses.first, 0, context);
      final uri = Uri(
        scheme: 'https',
        host: addresses.first.address,
        port: server.port,
      );
      final pem = await File(cert).readAsString();
      final der = base64Decode(
        pem.split('\n').where((l) => !l.startsWith('---')).join(),
      );
      final actualPin = sha256.convert(der).toString();
      final seen = <String?>[];
      final sub = server.listen((request) {
        seen.add(request.headers.value('x-agentlink-device-token'));
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"status":"ok","protocolVersion":1}');
        request.response.close();
      });
      final previous = HttpOverrides.current;
      HttpOverrides.global = RealHttp();
      final wrong = PinnedDeviceTransport(uri, pin, deviceToken: 'SECRET');
      final correct = PinnedDeviceTransport(
        uri,
        actualPin,
        deviceToken: 'SECRET',
      );
      final bootstrap = PinnedDeviceTransport(uri, actualPin);
      try {
        await expectLater(
          wrong.send(http.Request('GET', uri.replace(path: '/health'))),
          throwsA(anything),
        );
        expect(seen, isEmpty);
        final api = HapiApi(uri, 'SECRET', transport: correct);
        expect((await api.health())['status'], 'ok');
        expect(seen, ['SECRET']);
        await expectLater(
          bootstrap.send(http.Request('GET', uri.replace(path: '/health'))),
          throwsA(anything),
        );
        await expectLater(
          correct.send(
            http.Request('GET', Uri.parse('https://192.168.1.1/health')),
          ),
          throwsA(anything),
        );
        expect(seen, hasLength(1));
      } finally {
        wrong.close();
        correct.close();
        bootstrap.close();
        HttpOverrides.global = previous;
        await sub.cancel();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
