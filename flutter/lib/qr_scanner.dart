import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'connection_policy.dart';
import 'domain.dart';

/// Opens the camera only after the user deliberately enters this route.
///
/// A successfully decoded value is returned once. Invalid QR content is left
/// on this page for the pairing flow to explain, rather than being requested.
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage>
    with WidgetsBindingObserver {
  // CameraX has one platform camera session. Routes can overlap while their
  // exit animation is running, so serialize operations across scanner pages.
  static Future<void> _cameraTail = Future<void>.value();
  static MobileScannerController? _activeController;

  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _stopped = false;
  bool _disposed = false;
  bool _cameraWanted = true;
  String? _cameraError;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _cameraTail.then(
      (_) => action(),
      onError: (_) => action(),
    );
    _cameraTail = operation.catchError((_) {});
    return operation;
  }

  Future<void> _start() => _serialize(() async {
    if (_stopped ||
        _disposed ||
        !_cameraWanted ||
        _controller.value.isRunning ||
        _controller.value.isStarting) {
      return;
    }
    try {
      final previous = _activeController;
      if (previous != null && !identical(previous, _controller)) {
        await previous.stop();
        if (identical(_activeController, previous)) {
          _activeController = null;
        }
      }
      await _controller.start();
      if (_stopped || _disposed || !_cameraWanted) {
        await _controller.stop();
        return;
      }
      if (_controller.value.isRunning) _activeController = _controller;
      final error = _controller.value.error;
      if (!mounted ||
          (error == null && _controller.value.hasCameraPermission)) {
        return;
      }
      setState(
        () => _cameraError =
            error?.errorCode == MobileScannerErrorCode.permissionDenied
            ? '相机权限未授予，请允许相机权限后重试。'
            : '无法启动相机，请检查相机权限后重试。',
      );
    } catch (_) {
      if (mounted && !_disposed) {
        setState(() => _cameraError = '无法启动相机，请检查相机权限后重试。');
      }
    }
  });

  Future<void> _stop() => _serialize(() async {
    if (!identical(_activeController, _controller)) return;
    await _controller.stop();
    if (identical(_activeController, _controller)) {
      _activeController = null;
    }
  });

  Future<void> _retry() async {
    setState(() => _cameraError = null);
    _cameraWanted = true;
    await _stop();
    await _start();
  }

  void _detect(BarcodeCapture capture) {
    if (_stopped ||
        _disposed ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true)
      return;
    final value = capture.barcodes.firstOrNull?.rawValue?.trim();
    if (value == null || value.isEmpty) return;
    try {
      PairingTarget.parseLink(value);
    } on HubException catch (error) {
      setState(() => _scanError = error.message);
      return;
    }
    _stopped = true;
    _cameraWanted = false;
    unawaited(_stop());
    Navigator.of(context).pop(value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_stopped || _disposed) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _cameraWanted = true;
        unawaited(_start());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _cameraWanted = false;
        unawaited(_stop());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cameraWanted = false;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      _serialize(() async {
        if (identical(_activeController, _controller)) {
          await _controller.stop();
          _activeController = null;
        }
        await _controller.dispose();
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<String>(
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) return;
      _stopped = true;
      _cameraWanted = false;
      unawaited(_stop());
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('扫码连接')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _cameraError == null
                  ? Stack(
                      children: [
                        MobileScanner(
                          controller: _controller,
                          useAppLifecycleState: false,
                          onDetect: _detect,
                          // `_start` turns controller failures into the retry
                          // state below. Suppress the package's transient
                          // default error while that state update is queued.
                          errorBuilder: (_, _) => const SizedBox.expand(),
                        ),
                        if (_scanError != null)
                          Align(
                            alignment: Alignment.topCenter,
                            child: Container(
                              margin: const EdgeInsets.all(16),
                              padding: const EdgeInsets.all(12),
                              color: Theme.of(
                                context,
                              ).colorScheme.errorContainer,
                              child: Text(_scanError!),
                            ),
                          ),
                      ],
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_cameraError!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: _retry,
                              child: const Text('重试'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('返回手动输入'),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('将电脑端的 AgentLink 配对二维码放入取景框'),
            ),
          ],
        ),
      ),
    ),
  );
}
