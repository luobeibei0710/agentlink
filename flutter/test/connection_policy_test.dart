import 'package:companion/connection_policy.dart';
import 'package:companion/domain.dart';
import 'package:companion/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'app_model_test.dart' show FakeApi, MemoryStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('LAN origins accept RFC1918 literals and preserve nondefault ports', () {
    for (final address in [
      '10.0.2.2',
      '172.16.0.2',
      '172.31.255.1',
      '192.168.1.2',
    ]) {
      expect(PairingTarget.parseHub('http://$address:3106').port, 3106);
    }
    expect(PairingTarget.parseHub('http://192.168.1.2:443').port, 443);
    expect(
      PairingTarget.parseHub('http://192.168.1.2:80').toString(),
      'http://192.168.1.2',
    );
    expect(
      PairingTarget.parseHub('https://Hub.Example:443/').toString(),
      'https://hub.example',
    );
  });
  test('public HTTP and malformed or ambiguous QR origins fail closed', () {
    for (final address in [
      'http://example.com',
      'http://8.8.8.8',
      'http://127.0.0.1',
      'http://172.32.0.1',
      'http://169.254.1.1',
      'http://10.0.0.256',
      'http://192.168.01.2',
      'http://192.168.1.2/path',
      'http://u:p@192.168.1.2',
      'http://192.168.1.2:0',
      'ftp://192.168.1.2',
    ]) {
      expect(
        () => PairingTarget.parseHub(address),
        throwsA(isA<HubException>()),
        reason: address,
      );
    }
    final encoded = Uri(
      queryParameters: {'hub': 'http://192.168.1.2:3106', 'code': 'a+b&c'},
    ).query;
    final target = PairingTarget.parseLink('hapicompanion://bind?$encoded');
    expect(target.code, 'a+b&c');
    expect(target.isLan, isTrue);
    expect(
      () => PairingTarget.parseLink(
        'hapicompanion://bind?$encoded&hub=https://evil.test',
      ),
      throwsA(isA<HubException>()),
    );
    expect(
      () => PairingTarget.parseLink('hapicompanion://bind?$encoded#hidden'),
      throwsA(isA<HubException>()),
    );
  });
  test(
    'LAN requires consent and restored LAN sends nothing before reconfirmation',
    () async {
      final storage = MemoryStorage();
      int requests = 0;
      FakeApi factory(Uri hub, String token) {
        requests++;
        return FakeApi(hub: hub, token: token);
      }

      final model = AppModel(storage: storage, apiFactory: factory);
      await expectLater(
        model.pair('http://192.168.1.2:3106', 'code'),
        throwsA(isA<HubException>()),
      );
      expect(requests, 0);
      await model.pair('http://192.168.1.2:3106', 'code', allowLanHttp: true);
      expect(model.paired, isTrue);
      model.dispose();
      final restored = AppModel(storage: storage, apiFactory: factory);
      final beforeRestore = requests;
      await restored.restore();
      expect(requests, beforeRestore);
      expect(restored.pendingLanHub, 'http://192.168.1.2:3106');
      expect(restored.paired, isFalse);
      await restored.reconnectLan();
      expect(restored.paired, isTrue);
      expect(restored.pendingLanHub, isNull);
      restored.dispose();
    },
  );
}
