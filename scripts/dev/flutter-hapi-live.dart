// Exercises the Flutter client's actual HTTP/decoder implementation against a live HAPI hub.
import 'dart:io';
import '../../flutter/lib/hapi_api.dart';

Future<void> main() async {
  final hub = Platform.environment['AGENTLINK_TEST_HUB'];
  final token = Platform.environment['AGENTLINK_TEST_TOKEN'];
  final sessionId = Platform.environment['AGENTLINK_TEST_SESSION'];
  if (hub == null || token == null || sessionId == null) {
    throw StateError('Use this through agentlink-live-smoke.mjs');
  }
  final api = HapiApi(Uri.parse(hub), token);
  final health = await api.health();
  if (health['protocolVersion'] != 1) throw StateError('Wrong protocol');
  await api.authenticate();
  final sessions = await api.sessions();
  if (!sessions.any((s) => s.id == sessionId)) throw StateError('Flutter cannot see live session');
  final localId = 'flutter-live-${DateTime.now().microsecondsSinceEpoch}';
  await api.send(sessionId, 'No tools. Reply exactly AGENTLINK_FLUTTER_READY.', localId);
  final until = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(until)) {
    final messages = await api.messages(sessionId);
    if (messages.any((m) => m.role == 'agent' && m.text.contains('AGENTLINK_FLUTTER_READY'))) {
      stdout.writeln('PASS Flutter HapiApi real auth/list/send/decode reply');
      exit(0);
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  throw StateError('Flutter protocol client did not decode a real Agent reply');
}
