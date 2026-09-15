import 'dart:convert';
import 'dart:io';

import 'package:companion/device_discovery.dart';
import 'package:companion/trusted_devices.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_model_test.dart' show MemoryStorage;
import 'trusted_devices_test.dart' show RealHttp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final address = Platform.environment['AGENTLINK_LIVE_ADDRESS'];
  test(
    'live discovery, SAS approval, saved reconnect, immediate revocation',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = RealHttp();
      final client = HttpClient();
      final home = Platform.environment['AGENTLINK_LIVE_HOME']!;
      final adminState =
          jsonDecode(
                await File('$home/device-link/devices.json').readAsString(),
              )
              as Map;
      Future<Map<String, dynamic>> admin(
        String path, {
        bool post = false,
      }) async {
        final request = await client.openUrl(
          post ? 'POST' : 'GET',
          Uri.parse('http://127.0.0.1:3109$path'),
        );
        request.headers.set(
          'x-agentlink-admin',
          adminState['adminToken'] as String,
        );
        request.headers.set('origin', 'http://127.0.0.1:3109');
        final response = await request.close();
        expect(response.statusCode, 200);
        return jsonDecode(await utf8.decodeStream(response))
            as Map<String, dynamic>;
      }

      final discovery = DeviceDiscovery();
      final candidates = <NearbyComputer>[];
      final service = DevicePairingService(deviceName: '自动联调测试设备');
      PendingDevicePair? pending;
      TrustedComputer? paired;
      try {
        await discovery.scan(
          candidates.add,
          duration: const Duration(seconds: 3),
        );
        final matching = candidates
            .where((c) => c.uri.host == address)
            .toList();
        expect(
          matching,
          isNotEmpty,
          reason: 'Actual LAN broadcast must discover the running desktop host',
        );
        pending = await service.begin(matching.first);
        expect(await service.poll(pending), isNull);
        final requests = (await admin('/admin/requests'))['requests'] as List;
        final own = requests.cast<Map>().singleWhere(
          (row) => row['requestId'] == pending!.requestId,
        );
        expect(
          own['sas'],
          pending.digits,
          reason: 'Phone and physical-PC transcript must match',
        );
        await admin('/admin/requests/${pending.requestId}/approve', post: true);
        paired = await service.poll(pending);
        expect(paired, isNotNull);
        final storage = MemoryStorage();
        await TrustedDeviceRegistry(storage: storage).save(paired!);
        final registry = TrustedDeviceRegistry(storage: storage);
        await registry.load();
        final api = service.api(registry.computers.single);
        try {
          expect((await api.health())['status'], 'ok');
          await api.authenticate();
          expect((await api.machines()).where((m) => m.active), isNotEmpty);
          await api.sessions();
          await admin('/admin/devices/${paired.deviceId}/revoke', post: true);
          await expectLater(api.sessions(), throwsA(anything));
        } finally {
          api.close();
        }
        final reconnect = service.api(registry.computers.single);
        try {
          await expectLater(reconnect.authenticate(), throwsA(anything));
        } finally {
          reconnect.close();
        }
      } finally {
        if (paired != null)
          await admin('/admin/devices/${paired.deviceId}/revoke', post: true);
        pending?.close();
        discovery.close();
        client.close(force: true);
        HttpOverrides.global = previous;
      }
    },
    skip: address == null
        ? 'Set AGENTLINK_LIVE_ADDRESS and AGENTLINK_LIVE_HOME for the running desktop integration.'
        : false,
  );
}
