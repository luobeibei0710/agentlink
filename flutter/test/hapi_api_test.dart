import 'dart:convert';
import 'package:companion/hapi_api.dart';
import 'package:companion/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class FakeTransport implements HapiTransport {
  final List<http.Request> requests = [];
  final List<http.Response> responses;
  FakeTransport(this.responses);
  @override
  Future<http.Response> send(http.Request r) async {
    requests.add(r);
    return responses.removeAt(0);
  }

  @override
  void close() {}
}

void main() {
  test(
    'LAN authentication never forwards a credential through redirects',
    () async {
      final transport = FakeTransport([
        http.Response(
          '{}',
          302,
          headers: {'location': 'http://other.example/auth'},
        ),
      ]);
      final api = HapiApi(
        Uri.parse('http://192.168.1.216:3106'),
        'secret',
        transport: transport,
      );
      await expectLater(api.authenticate(), throwsA(isA<HubException>()));
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.followRedirects, isFalse);
    },
  );
  test(
    'public HTTP cannot reach the transport even outside pairing UI',
    () async {
      final transport = FakeTransport([]);
      final api = HapiApi(
        Uri.parse('http://public.example'),
        'secret',
        transport: transport,
      );
      await expectLater(api.health(), throwsA(isA<HubException>()));
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'message page sends composite cursors and parses all watermarks',
    () async {
      final t = FakeTransport([
        http.Response(jsonEncode({'token': 'jwt'}), 200),
        http.Response(
          jsonEncode({
            'messages': [],
            'page': {
              'direction': 'after',
              'limit': 50,
              'epoch': 3,
              'reset': true,
              'nextBeforeSeq': 1,
              'nextBeforeAt': 2,
              'nextAfterSeq': 5,
              'nextAfterAt': 6,
              'snapshotHeadSeq': 7,
              'snapshotHeadAt': 8,
              'hasMore': true,
            },
          }),
          200,
        ),
      ]);
      final api = HapiApi(
        Uri.parse('https://hub.test'),
        'access',
        transport: t,
      );
      final page = await api.messagePageWithCursors(
        's',
        afterSeq: 3,
        afterAt: 4,
        untilSeq: 9,
        untilAt: 10,
        epoch: 2,
      );
      expect(t.requests.last.url.queryParameters['afterSeq'], '3');
      expect(t.requests.last.url.queryParameters['untilAt'], '10');
      expect(page.afterAt, 6);
      expect(page.snapshotHeadSeq, 7);
      expect(page.reset, isTrue);
    },
  );
  test('rpc success false and non-json errors become HubException', () async {
    final t = FakeTransport([
      http.Response(jsonEncode({'token': 'jwt'}), 200),
      http.Response('<html>bad gateway</html>', 502),
    ]);
    final api = HapiApi(Uri.parse('https://hub.test'), 'access', transport: t);
    expect(() => api.machines(), throwsA(isA<Object>()));
  });
  test('availability reads available agent flag', () async {
    final t = FakeTransport([
      http.Response(jsonEncode({'token': 'jwt'}), 200),
      http.Response(
        jsonEncode({
          'agents': [
            {'agent': 'codebuddy', 'available': true},
          ],
        }),
        200,
      ),
    ]);
    final api = HapiApi(Uri.parse('https://hub.test'), 'access', transport: t);
    expect(await api.machineCanRun('m', 'codebuddy'), isTrue);
  });
  test('spawn requires a non-empty response session id', () async {
    final t = FakeTransport([
      http.Response(jsonEncode({'token': 'jwt'}), 200),
      http.Response(jsonEncode({'type': 'success', 'sessionId': ''}), 200),
    ]);
    final api = HapiApi(Uri.parse('https://hub.test'), 'access', transport: t);
    await expectLater(
      api.spawn('m', '/work', 'codebuddy'),
      throwsA(isA<HubException>()),
    );
  });
  test(
    'cancel response keeps invoked message instead of treating it as cancelled',
    () async {
      final t = FakeTransport([
        http.Response(jsonEncode({'token': 'jwt'}), 200),
        http.Response(
          jsonEncode({
            'status': 'invoked',
            'message': {
              'id': 'm',
              'content': {
                'role': 'agent',
                'content': {
                  'type': 'codex',
                  'data': {'type': 'message', 'message': 'sent'},
                },
              },
            },
          }),
          200,
        ),
      ]);
      final result = await HapiApi(
        Uri.parse('https://hub.test'),
        'access',
        transport: t,
      ).cancelMessage('s', 'm');
      expect(result.invoked, isTrue);
      expect(result.cancelled, isFalse);
      expect(result.message?.text, 'sent');
    },
  );
}
