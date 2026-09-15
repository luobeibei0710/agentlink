import 'dart:convert';

import 'package:companion/agentlink_theme.dart';
import 'package:companion/app_model.dart';
import 'package:companion/device_discovery.dart';
import 'package:companion/device_page.dart';
import 'package:companion/domain.dart';
import 'package:companion/main.dart';
import 'package:companion/trusted_devices.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_model_test.dart' show FakeApi, MemoryStorage;
import 'device_page_test.dart' show computer, saved;

/// 同时报告已配对与全新发现的电脑，让一张快照覆盖两种列表行。
class _TwoComputers extends DeviceDiscovery {
  @override
  Future<void> scan(
    void Function(NearbyComputer) onComputer, {
    Duration duration = const Duration(seconds: 6),
  }) async {
    onComputer(computer);
    onComputer(
      NearbyComputer(
        name: '客厅的 Mac mini',
        hostId: 'b' * 64,
        uri: Uri.parse('https://192.168.1.7:3107'),
      ),
    );
  }
}

/// 具备机器与 Agent 可用性数据的替身，供新会话弹窗使用。
class _DialogApi extends FakeApi {
  @override
  Future<List<Machine>> machines() async =>
      const [Machine(id: 'm1', name: '我的 Mac', active: true)];
  @override
  Future<List<AgentAvailability>> agentAvailability(String machineId) async =>
      const [
        AgentAvailability(agent: 'codex', available: true),
        AgentAvailability(agent: 'codebuddy', available: true),
      ];
}

void _sizePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  _sizePhone(tester);
  await tester.pumpWidget(MaterialApp(theme: agentLinkTheme(), home: home));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the pairing form without marketing chrome', (
    tester,
  ) async {
    final model = AppModel(persistState: false);
    await _pump(tester, Pairing(model));
    await expectLater(
      find.byType(Pairing),
      matchesGoldenFile('goldens/pairing.png'),
    );
    model.dispose();
  });

  testWidgets('renders the device page in the shared list style', (
    tester,
  ) async {
    final model = AppModel(persistState: false);
    final storage = MemoryStorage();
    storage.values['agentlink.trusted-devices.v1'] = jsonEncode([
      saved.toJson(),
    ]);
    await _pump(
      tester,
      DevicePage(
        model: model,
        isRoot: true,
        onManual: () {},
        registry: TrustedDeviceRegistry(storage: storage),
        discoveryFactory: _TwoComputers.new,
      ),
    );
    await expectLater(
      find.byType(DevicePage),
      matchesGoldenFile('goldens/devices.png'),
    );
    model.dispose();
  });

  testWidgets('renders the new session dialog in the shared style', (
    tester,
  ) async {
    final model = AppModel(
      apiFactory: (_, _) => _DialogApi(),
      persistState: false,
    );
    await model.pair('hub.example', 'token');
    _sizePhone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: agentLinkTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => NewSessionDialog(model),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(NewSessionDialog),
      matchesGoldenFile('goldens/new_session.png'),
    );
    model.dispose();
  });
}
