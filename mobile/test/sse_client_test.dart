import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nibble/core/network/sse_client.dart';
import 'package:nibble/features/pairing/pairing_model.dart';

class ClosableMockClient extends MockClient {
  bool isClosed = false;
  ClosableMockClient(super.fn);

  @override
  void close() {
    isClosed = true;
    super.close();
  }
}

void main() {
  group('SseNetworkClient', () {
    test('parses SSE JSON event frames from /api/events', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        if (request.url.path == '/api/events') {
          return http.Response(
            'data: {"kind":"hello","cursor":"a:0"}\n\n'
            'id: a:1\ndata: {"kind":"message","message":{"text":"Hello world"}}\n\n'
            'id: a:2\ndata: {"kind":"message","message":{"text":"from Nibble"}}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'omb_testtok',
        httpClient: mockClient,
      );

      final events = await sseClient.streamEvents().toList();
      expect(events.map((event) => event.kind).toList(), ['hello', 'message', 'message']);
      expect(events[1].id, 'a:1');
      expect(events[1].data['message']['text'], 'Hello world');
    });

    test('sends Authorization, Accept, and optional Last-Event-ID headers in stream', () async {
      String? capturedAuth;
      String? capturedAccept;
      String? capturedLastEventId;
      String? capturedPath;

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        if (request.url.path == '/api/events') {
          capturedPath = request.url.path;
          capturedAuth = request.headers['authorization'];
          capturedAccept = request.headers['accept'];
          capturedLastEventId = request.headers['last-event-id'];
          return http.Response(
            'data: {"kind":"hello"}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'omb_test-token-xyz',
        httpClient: mockClient,
      );

      final events = await sseClient.streamEvents(lastEventId: 'evt-99').toList();

      expect(events, isNotEmpty);
      expect(capturedPath, '/api/events');
      expect(capturedAuth, 'Bearer omb_test-token-xyz');
      expect(capturedAccept, 'text/event-stream');
      expect(capturedLastEventId, 'evt-99');
    });

    test('throws Exception when stream endpoint returns non-200 status', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        return http.Response('Unauthorized', 401);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'bad-token',
        httpClient: mockClient,
      );

      expect(
        () => sseClient.streamEvents().toList(),
        throwsA(isA<Exception>()),
      );
    });

    test('resolveActiveBaseUrl probes /api/health with Authorization', () async {
      String? capturedAuth;
      String? capturedPath;
      final mockClient = MockClient((request) async {
        capturedAuth = request.headers['authorization'];
        capturedPath = request.url.path;
        if (request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'omb_probe-secret-token',
        httpClient: mockClient,
      );

      await sseClient.resolveActiveBaseUrl();
      expect(capturedPath, '/api/health');
      expect(capturedAuth, 'Bearer omb_probe-secret-token');
    });

    test('resolveActiveBaseUrl prefers LAN when health check succeeds', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == '192.168.1.100' && request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        endpoints: const [
          CompanionEndpoint(url: 'https://c-hosted.openmausbot.com', kind: 'hosted', priority: 0),
          CompanionEndpoint(url: 'http://192.168.1.100:8810', kind: 'lan', priority: 200),
        ],
        deviceToken: 'omb_test-tok',
        httpClient: mockClient,
      );

      final activeUrl = await sseClient.resolveActiveBaseUrl();
      expect(activeUrl, 'http://192.168.1.100:8810');
    });

    test('resolveActiveBaseUrl falls back to hosted when LAN health check fails', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == '192.168.1.100') {
          return http.Response('Error', 500);
        }
        if (request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        endpoints: const [
          CompanionEndpoint(url: 'http://192.168.1.100:8810', kind: 'lan', priority: 200),
          CompanionEndpoint(url: 'https://c-hosted.openmausbot.com', kind: 'hosted', priority: 0),
        ],
        deviceToken: 'omb_test-tok',
        httpClient: mockClient,
      );

      final activeUrl = await sseClient.resolveActiveBaseUrl();
      expect(activeUrl, 'https://c-hosted.openmausbot.com');
    });

    test('resolveActiveBaseUrl returns first endpoint if none are healthy', () async {
      final mockClient = MockClient((request) async {
        throw http.ClientException('Connection refused');
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://192.168.1.100:8810',
        remoteUrl: null,
        deviceToken: 'omb_test-tok',
        httpClient: mockClient,
      );

      final activeUrl = await sseClient.resolveActiveBaseUrl();
      expect(activeUrl, 'http://192.168.1.100:8810');
    });

    test('strips trailing slashes from endpoint URLs', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810///',
        remoteUrl: 'https://remote.example.com///',
        deviceToken: 'omb_test-tok',
        httpClient: mockClient,
      );

      expect(sseClient.lanUrl, 'http://127.0.0.1:8810');
      expect(sseClient.remoteUrl, 'https://remote.example.com');
      final activeUrl = await sseClient.resolveActiveBaseUrl();
      expect(activeUrl, 'http://127.0.0.1:8810');
    });

    test('sendBotMessage posts to /api/bots/:id/messages with text', () async {
      String? capturedAuth;
      String? capturedBody;
      String? capturedPath;

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        if (request.method == 'POST') {
          capturedAuth = request.headers['authorization'];
          capturedBody = request.body;
          capturedPath = request.url.path;
          return http.Response('{"ok":true}', 202);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'omb_test-tok-post',
        httpClient: mockClient,
      );

      final success = await sseClient.sendBotMessage(
        botId: 'bot-main',
        text: 'test message',
      );

      expect(success, isTrue);
      expect(capturedPath, '/api/bots/bot-main/messages');
      expect(capturedAuth, 'Bearer omb_test-tok-post');
      expect(jsonDecode(capturedBody!), {'text': 'test message'});
    });

    test('respondApproval posts behavior to /api/bots/:id/respond', () async {
      String? capturedPath;
      String? capturedBody;

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        if (request.method == 'POST') {
          capturedPath = request.url.path;
          capturedBody = request.body;
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'omb_test-tok',
        httpClient: mockClient,
      );

      final success = await sseClient.respondApproval(
        botId: 'bot-main',
        threadId: 'thread-1',
        requestId: 'req-9',
        behavior: 'allow',
      );

      expect(success, isTrue);
      expect(capturedPath, '/api/bots/bot-main/respond');
      expect(jsonDecode(capturedBody!), {
        'threadId': 'thread-1',
        'requestId': 'req-9',
        'behavior': 'allow',
      });
    });

    test('postJson returns false on non-2xx status code', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/health') {
          return http.Response('{"app":"nibble"}', 200);
        }
        return http.Response('Bad request', 400);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'omb_test-tok',
        httpClient: mockClient,
      );

      final success = await sseClient.postJson('/api/invalid', {'bad': 'input'});
      expect(success, isFalse);
    });

    test('redeemPair stores companion token from 201 response', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, '/api/pair');
        expect(request.method, 'POST');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['credential'], 'omb_pair_abc');
        expect(body['deviceName'], 'Phone');
        return http.Response(
          jsonEncode({
            'token': 'omb_device_token_value_123456789012345678901',
            'device': {'id': 'd1', 'name': 'Phone'},
            'serverName': 'Studio',
            'endpoints': [
              {'url': 'http://192.168.1.8:8810', 'kind': 'lan', 'priority': 200},
            ],
          }),
          201,
        );
      });

      final result = await SseNetworkClient.redeemPair(
        baseUrl: 'http://192.168.1.8:8810',
        credential: 'omb_pair_abc',
        deviceName: 'Phone',
        httpClient: mockClient,
      );

      expect(result.token, startsWith('omb_'));
      expect(result.serverName, 'Studio');
      expect(result.endpoints.single.kind, 'lan');
    });

    test('close closes the underlying http client', () {
      final mockClient = ClosableMockClient((request) async => http.Response('ok', 200));
      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'omb_test-tok',
        httpClient: mockClient,
      );

      expect(mockClient.isClosed, isFalse);
      sseClient.close();
      expect(mockClient.isClosed, isTrue);
    });
  });
}
