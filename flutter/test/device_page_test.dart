import 'dart:async';
import 'dart:convert';

import 'package:companion/app_model.dart';
import 'package:companion/device_discovery.dart';
import 'package:companion/device_page.dart';
import 'package:companion/hapi_api.dart';
import 'package:companion/trusted_devices.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_model_test.dart' show FakeApi, MemoryStorage;

final computer = NearbyComputer(
  name: '我的 Mac',
  hostId: 'a' * 64,
  uri: Uri.parse('https://192.168.1.2:3107'),
);
final saved = TrustedComputer(
  hostId: computer.hostId,
  name: computer.name,
  uri: computer.uri,
  deviceId: 'd',
  token: 'T' * 43,
);

class FoundComputer extends DeviceDiscovery {
  @override
  Future<void> scan(
    void Function(NearbyComputer) onComputer, {
    Duration duration = const Duration(seconds: 6),
  }) async {
    onComputer(computer);
  }
}

class PairingFake extends DevicePairingService {
  int apiCalls = 0, beginCalls = 0;
  final pendingPoll = Completer<TrustedComputer?>();
  @override
  Future<void> cancel(PendingDevicePair pair) async {}
  @override
  Future<PendingDevicePair> begin(NearbyComputer computer) async {
    beginCalls++;
    return PendingDevicePair(
      computer: computer,
      transport: PinnedDeviceTransport(computer.uri, computer.hostId),
      requestId: 'R' * 43,
      clientNonce: 'N' * 43,
      digits: '12345678',
      expiresAt: DateTime.now().add(const Duration(minutes: 2)),
    );
  }

  @override
  Future<TrustedComputer?> poll(PendingDevicePair pair) => pendingPoll.future;
  @override
  HapiApi api(TrustedComputer computer) {
    apiCalls++;
    return FakeApi(hub: computer.uri);
  }
}

void main() {
  testWidgets(
    'discovered first connection shows SAS, cancellation sends no API authorization',
    (tester) async {
      final model = AppModel(persistState: false), service = PairingFake();
      final registry = TrustedDeviceRegistry(storage: MemoryStorage());
      await tester.pumpWidget(
        MaterialApp(
          home: DevicePage(
            model: model,
            isRoot: true,
            onManual: () {},
            registry: registry,
            pairingService: service,
            discoveryFactory: FoundComputer.new,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的 Mac'));
      await tester.pumpAndSettle();
      expect(find.text('1234  5678'), findsOneWidget);
      expect(service.apiCalls, 0);
      await tester.tap(find.text('取消连接'));
      service.pendingPoll.complete(saved); // Late PC approval must not connect.
      await tester.pumpAndSettle();
      expect(service.apiCalls, 0);
      expect(registry.computers, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );
  testWidgets('saved computer connects with one tap without a new approval', (
    tester,
  ) async {
    final model = AppModel(persistState: false), service = PairingFake();
    final storage = MemoryStorage();
    storage.values['agentlink.trusted-devices.v1'] = jsonEncode([
      saved.toJson(),
    ]);
    final registry = TrustedDeviceRegistry(storage: storage);
    await tester.pumpWidget(
      MaterialApp(
        home: DevicePage(
          model: model,
          isRoot: true,
          onManual: () {},
          registry: registry,
          pairingService: service,
          discoveryFactory: FoundComputer.new,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的 Mac'));
    await tester.pumpAndSettle();
    expect(service.beginCalls, 0);
    expect(service.apiCalls, 1);
    expect(model.paired, isTrue);
    expect(model.hub, 'device:${saved.hostId}');
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets(
    'home page offers one-tap reconnect for a saved LAN computer',
    (tester) async {
      // 冷启动与 reconnectLan 的语义由 connection_policy_test 覆盖；
      // 这里只验证入口本身出现在首页，无需先进入手动配对页。
      final model = AppModel(persistState: false)
        ..pendingLanHub = 'http://192.168.1.5:3106';
      final registry = TrustedDeviceRegistry(storage: MemoryStorage());
      await tester.pumpWidget(
        MaterialApp(
          home: DevicePage(
            model: model,
            isRoot: true,
            onManual: () {},
            registry: registry,
            pairingService: PairingFake(),
            discoveryFactory: FoundComputer.new,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('上次连接的电脑'), findsOneWidget);
      expect(find.textContaining('192.168.1.5:3106'), findsWidgets);

      await tester.tap(find.text('上次连接的电脑'));
      await tester.pumpAndSettle();
      expect(find.text('重新连接已保存的电脑？'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(model.paired, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );
}
