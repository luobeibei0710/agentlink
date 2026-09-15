import 'dart:async';

import 'package:companion/app_model.dart';
import 'package:companion/connection_policy.dart';
import 'package:companion/domain.dart';
import 'package:companion/main.dart';
import 'package:companion/qr_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class CountingPairingModel extends AppModel {
  CountingPairingModel() : super(persistState: false);

  int pairCalls = 0;

  @override
  Future<void> pair(
    String rawHub,
    String token, {
    bool persist = true,
    bool allowLanHttp = false,
  }) async {
    pairCalls++;
  }
}

class FakeScannerPlatform extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  final torches = StreamController<TorchState>.broadcast();
  final zoom = StreamController<double>.broadcast();

  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => torches.stream;
  @override
  Stream<double> get zoomScaleStateStream => zoom.stream;
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async =>
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        size: Size(100, 100),
      );
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}

  Future<void> close() async {
    await captures.close();
    await torches.close();
    await zoom.close();
  }
}

void main() {
  test('scanner accepts only a complete AgentLink pairing QR', () {
    final target = PairingTarget.parseLink(
      'hapicompanion://bind?hub=https%3A%2F%2Fhub.example&code=secret',
    );

    expect(target.uri, Uri.parse('https://hub.example'));
    expect(target.code, 'secret');
  });

  test('scanner QR rejects malformed and public HTTP targets', () {
    expect(
      () => PairingTarget.parseLink('https://hub.example/?code=secret'),
      throwsA(isA<HubException>()),
    );
    expect(
      () => PairingTarget.parseLink(
        'hapicompanion://bind?hub=http%3A%2F%2Fhub.example&code=secret',
      ),
      throwsA(isA<HubException>()),
    );
  });

  testWidgets(
    'invalid input is visible and cancelled LAN confirmation does not pair',
    (tester) async {
      final model = CountingPairingModel();
      await tester.pumpWidget(MaterialApp(home: Pairing(model)));

      await tester.enterText(
        find.byType(TextField).first,
        'http://hub.example',
      );
      final connect = find.text('连接工作台');
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.pump();
      expect(find.textContaining('HTTP 仅支持'), findsOneWidget);
      expect(model.pairCalls, 0);

      await tester.enterText(
        find.byType(TextField).first,
        'http://192.168.1.9',
      );
      await tester.enterText(find.byType(TextField).at(1), 'secret');
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(find.textContaining('传输不使用 HTTPS'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(model.pairCalls, 0);
      model.dispose();
    },
  );

  testWidgets('late barcode from an exiting scanner cannot pop a new scanner', (
    tester,
  ) async {
    final oldPlatform = MobileScannerPlatform.instance;
    final platform = FakeScannerPlatform();
    MobileScannerPlatform.instance = platform;
    addTearDown(() async {
      MobileScannerPlatform.instance = oldPlatform;
      await platform.close();
    });
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const QrScannerPage())),
            child: const Text('open scanner'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open scanner'));
    await tester.pumpAndSettle();
    final oldDetect = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .onDetect!;

    await tester.pageBack();
    await tester.pump();
    navigator.currentState!.push(
      MaterialPageRoute(builder: (_) => const QrScannerPage()),
    );
    await tester.pump();

    oldDetect(
      const BarcodeCapture(
        barcodes: [
          Barcode(
            rawValue:
                'hapicompanion://bind?hub=https%3A%2F%2Fhub.example&code=late',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QrScannerPage), findsOneWidget);
  });
}
