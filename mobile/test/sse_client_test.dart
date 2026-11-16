import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/network/sse_client.dart';

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
    test('parses SSE data chunks properly', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        if (request.url.path.contains('/messages')) {
          return http.Response(
            'data: Hello world\n\ndata: from OpenMausBot\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'test-tok',
        httpClient: mockClient,
      );

      final chunks = await sseClient.streamMessages('th-123').toList();
      expect(chunks, ['Hello world', 'from OpenMausBot']);
    });

    test('sends Authorization, Accept, and optional Last-Event-ID headers in stream', () async {
      String? capturedAuth;
      String? capturedAccept;
      String? capturedLastEventId;

      final mockClient = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        if (request.url.path.contains('/messages')) {
          capturedAuth = request.headers['authorization'];
          capturedAccept = request.headers['accept'];
          capturedLastEventId = request.headers['last-event-id'];
          return http.Response(
            'data: chunk1\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'test-token-xyz',
        httpClient: mockClient,
      );

      final chunks = await sseClient
          .streamMessages('th-456', lastEventId: 'evt-99')
          .toList();

      expect(chunks, ['chunk1']);
      expect(capturedAuth, 'Bearer test-token-xyz');
      expect(capturedAccept, 'text/event-stream');
      expect(capturedLastEventId, 'evt-99');
    });

    test('throws Exception when stream endpoint returns non-200 status', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Unauthorized', 401);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'bad-token',
        httpClient: mockClient,
      );

      expect(
        () => sseClient.streamMessages('th-err').toList(),
        throwsA(isA<Exception>()),
      );
    });

    test('resolveActiveBaseUrl sends Authorization header during health check', () async {
      String? capturedAuth;
      final mockClient = MockClient((request) async {
        if (request.url.path == '/healthz') {
          capturedAuth = request.headers['authorization'];
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'probe-secret-token',
        httpClient: mockClient,
      );

      await sseClient.resolveActiveBaseUrl();
      expect(capturedAuth, 'Bearer probe-secret-token');
    });

    test('resolveActiveBaseUrl prefers LAN when health check succeeds', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == '192.168.1.100' && request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://192.168.1.100:8810',
        remoteUrl: 'https://tailscale.openmausbot.ts.net:8810',
        deviceToken: 'test-tok',
        httpClient: mockClient,
      );

      final activeUrl = await sseClient.resolveActiveBaseUrl();
      expect(activeUrl, 'http://192.168.1.100:8810');
    });

    test('resolveActiveBaseUrl falls back to remoteUrl when LAN health check fails', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == '192.168.1.100') {
          return http.Response('Error', 500);
        }
        return http.Response('{"status":"ok"}', 200);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://192.168.1.100:8810',
        remoteUrl: 'https://tailscale.openmausbot.ts.net:8810',
        deviceToken: 'test-tok',
        httpClient: mockClient,
      );

      final activeUrl = await sseClient.resolveActiveBaseUrl();
      expect(activeUrl, 'https://tailscale.openmausbot.ts.net:8810');
    });

    test('resolveActiveBaseUrl returns lanUrl if LAN fails and remoteUrl is not configured', () async {
      final mockClient = MockClient((request) async {
        throw http.ClientException('Connection refused');
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://192.168.1.100:8810',
        remoteUrl: null,
        deviceToken: 'test-tok',
        httpClient: mockClient,
      );

      final activeUrl = await sseClient.resolveActiveBaseUrl();
      expect(activeUrl, 'http://192.168.1.100:8810');
    });

    test('strips trailing slashes from lanUrl and remoteUrl', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810///',
        remoteUrl: 'https://remote.example.com///',
        deviceToken: 'test-tok',
        httpClient: mockClient,
      );

      expect(sseClient.lanUrl, 'http://127.0.0.1:8810');
      expect(sseClient.remoteUrl, 'https://remote.example.com');
      final activeUrl = await sseClient.resolveActiveBaseUrl();
      expect(activeUrl, 'http://127.0.0.1:8810');
    });

    test('postJson attaches headers, serializes body, and returns true on success', () async {
      String? capturedAuth;
      String? capturedContentType;
      String? capturedBody;
      String? capturedPath;

      final mockClient = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        if (request.method == 'POST') {
          capturedAuth = request.headers['authorization'];
          capturedContentType = request.headers['content-type'];
          capturedBody = request.body;
          capturedPath = request.url.path;
          return http.Response('{"success":true}', 200);
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'test-tok-post',
        httpClient: mockClient,
      );

      final success = await sseClient.postJson(
        '/api/threads/th-1/messages',
        {'content': 'test message'},
      );

      expect(success, isTrue);
      expect(capturedPath, '/api/threads/th-1/messages');
      expect(capturedAuth, 'Bearer test-tok-post');
      expect(capturedContentType, 'application/json');
      expect(jsonDecode(capturedBody!), {'content': 'test message'});
    });

    test('postJson returns false on non-2xx status code', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Bad request', 400);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'test-tok',
        httpClient: mockClient,
      );

      final success = await sseClient.postJson('/api/invalid', {'bad': 'input'});
      expect(success, isFalse);
    });

    test('postJson returns false on network or transport exception', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        throw http.ClientException('Network down');
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'test-tok',
        httpClient: mockClient,
      );

      final success = await sseClient.postJson('/api/broken', {'data': 1});
      expect(success, isFalse);
    });

    test('connectStream and resolveActiveEndpoint aliases function correctly', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        if (request.url.path.contains('/messages')) {
          return http.Response(
            'data: alias-msg\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response('Not found', 404);
      });

      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'test-tok',
        httpClient: mockClient,
      );

      final endpoint = await sseClient.resolveActiveEndpoint();
      expect(endpoint, 'http://127.0.0.1:8810');

      final chunks = await sseClient.connectStream('th-alias').toList();
      expect(chunks, ['alias-msg']);
    });

    test('close closes the underlying http client', () {
      final mockClient = ClosableMockClient((request) async => http.Response('ok', 200));
      final sseClient = SseNetworkClient(
        lanUrl: 'http://127.0.0.1:8810',
        deviceToken: 'test-tok',
        httpClient: mockClient,
      );

      expect(mockClient.isClosed, isFalse);
      sseClient.close();
      expect(mockClient.isClosed, isTrue);
    });
  });
}
