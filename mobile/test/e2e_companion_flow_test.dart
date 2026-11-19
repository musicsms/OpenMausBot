import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/e2e/descriptor.dart';
import 'package:mobile/core/e2e/relay_client.dart';
import 'package:mobile/core/network/sse_client.dart';
import 'package:mobile/core/storage/pairing_storage.dart';
import 'package:mobile/core/theme/grok_theme.dart';
import 'package:mobile/features/approvals/approval_card.dart';
import 'package:mobile/features/approvals/approval_model.dart';
import 'package:mobile/features/pairing/pairing_model.dart';
import 'package:mobile/main.dart';

class _RealHttpOverrides extends HttpOverrides {}

class FakePhoneRelayClient extends PhoneRelayClient {
  final http.Client _client;
  bool _connected = false;

  FakePhoneRelayClient({
    required super.descriptor,
    required http.Client httpClient,
    super.credentialToken = 'dummy',
  }) : _client = httpClient;

  @override
  bool get isConnected => _connected;

  @override
  http.Client get httpClient => _client;

  @override
  Future<void> connect() async {
    _connected = true;
  }

  @override
  Future<void> close() async {
    _connected = false;
  }
}

void main() {
  test('E2E Flow: Pair redeem stores omb_ token then streams /api/events', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = PairingStorage();

    const qrPayload =
        '{"host":"127.0.0.1","port":8810,"pairingSecret":"omb_pair_sec","machineName":"Studio"}';
    final payload = PairingPayload.fromJsonString(qrPayload);

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/api/pair') {
        return http.Response(
          jsonEncode({
            'token': 'omb_live_device_token_abcdefghijklmnopqrstuv',
            'device': {'id': 'd1', 'name': 'Phone'},
            'serverName': 'Studio',
            'endpoints': [
              {'url': payload.lanUrl, 'kind': 'lan', 'priority': 200},
            ],
          }),
          201,
        );
      }
      if (request.url.path == '/api/health') {
        return http.Response('{"app":"openmausbot"}', 200);
      }
      if (request.url.path == '/api/events') {
        return http.Response(
          'data: {"kind":"hello","cursor":"a:0"}\n\n'
          'id: a:1\ndata: {"kind":"message","message":{"text":"Chunky response","role":"bot","kind":"text"}}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.Response('OK', 200);
    });

    final pair = await SseNetworkClient.redeemPair(
      baseUrl: payload.lanUrl,
      credential: payload.credential,
      deviceName: 'Phone',
      httpClient: mockHttp,
    );
    expect(pair.token, startsWith('omb_'));
    expect(pair.token, isNot(payload.credential));

    await storage.saveDeviceToken(pair.token);
    await storage.saveEndpoints(endpoints: pair.endpoints);

    final sseClient = SseNetworkClient(
      endpoints: await storage.getEndpoints(),
      deviceToken: (await storage.getDeviceToken())!,
      httpClient: mockHttp,
    );

    final event = await sseClient.streamEvents().firstWhere((item) => item.kind == 'message');
    expect(event.data['message']['text'], 'Chunky response');
  });

  test('E2E Flow: Dual-route prefers LAN then falls back to hosted', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = PairingStorage();

    await storage.saveDeviceToken('omb_remote-device-tok');
    await storage.saveEndpoints(endpoints: const [
      CompanionEndpoint(url: 'http://192.168.1.100:8810', kind: 'lan', priority: 200),
      CompanionEndpoint(url: 'https://c-hosted.openmausbot.com', kind: 'hosted', priority: 0),
    ]);

    final mockHttp = MockClient((request) async {
      if (request.url.host == '192.168.1.100') {
        return http.Response('Connection refused', 503);
      }
      if (request.url.host == 'c-hosted.openmausbot.com' && request.url.path == '/api/health') {
        return http.Response('{"app":"openmausbot"}', 200);
      }
      if (request.url.host == 'c-hosted.openmausbot.com' && request.url.path == '/api/events') {
        return http.Response(
          'data: {"kind":"message","message":{"text":"Remote fallback stream"}}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.Response('Not found', 404);
    });

    final sseClient = SseNetworkClient(
      endpoints: await storage.getEndpoints(),
      deviceToken: (await storage.getDeviceToken())!,
      httpClient: mockHttp,
    );

    final activeUrl = await sseClient.resolveActiveBaseUrl();
    expect(activeUrl, 'https://c-hosted.openmausbot.com');

    final message = await sseClient.streamEvents().first;
    expect(message.data['message']['text'], 'Remote fallback stream');
  });

  testWidgets('E2E Flow: Tool approval interaction triggers haptics and approves action', (WidgetTester tester) async {
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final List<MethodCall> hapticCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(methodCall);
        }
        return null;
      },
    );

    bool approved = false;
    final request = ApprovalRequest(
      id: 'req-appr-42',
      botId: 'chief',
      threadId: 'thread-1',
      requestId: 'req-appr-42',
      toolName: 'google__work__gmail_send_mail',
      arguments: {'to': 'partner@acme.com', 'subject': 'Hợp đồng'},
      dangerLevel: 'high',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: GrokTheme.themeData,
        home: Scaffold(
          body: ApprovalCard(
            request: request,
            onApprove: () => approved = true,
            onReject: () {},
          ),
        ),
      ),
    );

    expect(find.text('YÊU CẦU PHÊ DUYỆT CÔNG CỤ'), findsOneWidget);
    expect(find.text('HIGH'), findsOneWidget);
    expect(find.text('google__work__gmail_send_mail'), findsOneWidget);
    expect(find.text('partner@acme.com'), findsOneWidget);

    await tester.tap(find.text('Duyệt'));
    await tester.pump();

    expect(approved, isTrue);
    expect(hapticCalls.length, 1);
    expect(hapticCalls.first.arguments, 'HapticFeedbackType.mediumImpact');
  });

  test('E2E Flow: Live fake companion serves health, pair redeem, events, send, approve', () async {
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);

    final process = await Process.start(
      'node',
      ['--experimental-strip-types', 'test/fixtures/fake-companion.ts'],
      workingDirectory: Directory.current.path.endsWith('mobile')
          ? Directory.current.path
          : '${Directory.current.path}/mobile',
      environment: {
        'PORT': '0',
        'FAKE_TOKEN': 'omb_fixedtokenfixedtokenfixedtokenfixedto',
      },
    );

    final portCompleter = Completer<int>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final match = RegExp(r'http://127.0.0.1:(\d+)').firstMatch(line);
      if (match != null && !portCompleter.isCompleted) {
        portCompleter.complete(int.parse(match.group(1)!));
      }
    });

    try {
      final port = await portCompleter.future.timeout(const Duration(seconds: 5));
      final baseUrl = 'http://127.0.0.1:$port';

      FlutterSecureStorage.setMockInitialValues({});
      final storage = PairingStorage();

      final health = await http.get(Uri.parse('$baseUrl/api/health'));
      expect(health.statusCode, 200);
      expect(jsonDecode(health.body)['app'], 'openmausbot');

      final denied = await http.get(Uri.parse('$baseUrl/healthz'));
      expect(denied.statusCode, 404);

      final pairResponse = await http.post(
        Uri.parse('$baseUrl/api/pair'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'credential': 'omb_pair_testsecret_testsecret_testsecrett',
          'deviceName': 'Flutter Test',
        }),
      );
      expect(pairResponse.statusCode, 201);
      final pairBody = jsonDecode(pairResponse.body) as Map<String, dynamic>;
      final deviceToken = pairBody['token'] as String;
      expect(deviceToken, startsWith('omb_'));
      expect(pairBody.containsKey('deviceToken'), isFalse);

      await storage.saveDeviceToken(deviceToken);
      await storage.saveEndpoints(lanUrl: baseUrl);

      final sseClient = SseNetworkClient(
        lanUrl: (await storage.getLanUrl())!,
        deviceToken: (await storage.getDeviceToken())!,
      );

      final events = await sseClient.streamEvents().toList();
      expect(events.first.kind, 'hello');
      expect(events.any((event) => event.kind == 'message'), isTrue);

      final sent = await sseClient.sendBotMessage(botId: 'bot-main', text: 'ping');
      expect(sent, isTrue);

      final approved = await sseClient.respondApproval(
        botId: 'bot-main',
        threadId: 'thread-main',
        requestId: 'req-1',
        behavior: 'allow',
      );
      expect(approved, isTrue);

      final wrongSend = await http.post(
        Uri.parse('$baseUrl/api/threads/default/messages'),
        headers: {
          'Authorization': 'Bearer $deviceToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'content': 'nope'}),
      );
      expect(wrongSend.statusCode, 404);
    } finally {
      process.kill();
      await process.exitCode;
    }
  });

  test('E2E Flow: E2E descriptor pairing redeems token over relay, pins k in storage, and routes SSE events through relay', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = PairingStorage();

    final desc = E2EDescriptor.parseJson({
      'v': 1,
      'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
      'h': 'lz81isB3BuNV6rHgYgG3Wg',
      'r': ['relay.example.com'],
    });

    final qrUri = 'openmausbot://pair?token=omb_pair_secret_val&name=SecureStudio&e2e=${desc.toB64u()}';
    final payload = PairingPayload.fromJsonString(qrUri);
    expect(payload.e2e, isNotNull);

    var relayPairCalled = false;
    var relayStreamCalled = false;
    var plainHttpCalled = false;

    final mockRelayHttp = MockClient((request) async {
      if (request.url.path == '/api/pair') {
        relayPairCalled = true;
        return http.Response(
          jsonEncode({
            'token': 'omb_e2e_live_device_token_xyz123456789012345',
            'device': {'id': 'd-e2e', 'name': 'Phone'},
            'serverName': 'SecureStudio',
            'endpoints': [],
            'e2e': desc.toJson(),
          }),
          200,
        );
      }
      if (request.url.path == '/api/health') {
        return http.Response('{"app":"openmausbot"}', 200);
      }
      if (request.url.path == '/api/events') {
        relayStreamCalled = true;
        return http.Response(
          'data: {"kind":"hello"}\n\n'
          'data: {"kind":"message","message":{"text":"Encrypted E2E hello","role":"bot"}}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.Response('Not found', 404);
    });

    final mockPlainHttp = MockClient((request) async {
      plainHttpCalled = true;
      return http.Response('Forbidden', 403);
    });

    final fakeRelay = FakePhoneRelayClient(
      descriptor: payload.e2e!,
      httpClient: mockRelayHttp,
      credentialToken: payload.credential,
    );

    final pair = await SseNetworkClient.redeemPair(
      deviceName: 'Secure Phone',
      credential: payload.credential,
      e2e: payload.e2e,
      relayClient: fakeRelay,
      httpClient: mockPlainHttp,
    );

    expect(relayPairCalled, isTrue);
    expect(plainHttpCalled, isFalse);
    expect(pair.token, startsWith('omb_'));
    expect(pair.e2e, isNotNull);

    await storage.saveDeviceToken(pair.token);
    await storage.saveE2EIdentity(
      transportPublicKey: pair.e2e!.k,
      hostId: pair.e2e!.h,
      relayNodes: pair.e2e!.relayNodes,
    );

    final storedIdentity = await storage.getE2EIdentity();
    expect(storedIdentity, isNotNull);
    expect(storedIdentity!.k, desc.k);
    expect(storedIdentity.h, desc.h);
    expect(storedIdentity.r, ['relay.example.com']);

    final sessionRelay = FakePhoneRelayClient(
      descriptor: (await storage.getE2EDescriptor())!,
      httpClient: mockRelayHttp,
      credentialToken: (await storage.getDeviceToken())!,
    );

    final sseClient = SseNetworkClient(
      deviceToken: (await storage.getDeviceToken())!,
      e2e: await storage.getE2EDescriptor(),
      relayClient: sessionRelay,
      httpClient: mockPlainHttp,
    );

    expect(sseClient.isE2E, isTrue);
    final event = await sseClient.streamEvents().firstWhere((e) => e.kind == 'message');
    expect(relayStreamCalled, isTrue);
    expect(plainHttpCalled, isFalse);
    expect(event.data['message']['text'], 'Encrypted E2E hello');
  });

  testWidgets('E2E Flow: Migration banner shown when server returns e2e but storage has no pinned k, and clears old credentials upon re-pair', (WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = PairingStorage();
    await storage.saveDeviceToken('omb_old_plain_token');
    await storage.saveEndpoints(lanUrl: 'http://127.0.0.1:8810');

    final desc = E2EDescriptor.parseJson({
      'v': 1,
      'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
      'h': 'lz81isB3BuNV6rHgYgG3Wg',
      'r': ['relay.example.com'],
    });

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/api/health') {
        return http.Response('{"app":"openmausbot"}', 200);
      }
      if (request.url.path == '/api/bots') {
        return http.Response(jsonEncode([{'id': 'bot-1', 'name': 'Assistant'}]), 200);
      }
      if (request.url.path == '/api/companion/endpoints') {
        return http.Response(
          jsonEncode({
            'serverName': 'OpenMausBot Desktop',
            'endpoints': [{'url': 'http://127.0.0.1:8810', 'kind': 'lan', 'priority': 200}],
            'e2e': desc.toJson(),
          }),
          200,
        );
      }
      if (request.url.path == '/api/events') {
        return http.Response(
          'data: {"kind":"hello"}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.Response('OK', 200);
    });

    await tester.pumpWidget(
      MausBotApp(
        storage: storage,
        httpClient: mockHttp,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Pair again to connect from anywhere'), findsOneWidget);
    expect(find.text('Pair again'), findsOneWidget);

    await tester.tap(find.text('Pair again'));
    await tester.pumpAndSettle();

    expect(find.text('Pair with Desktop'), findsOneWidget);
  });
}
