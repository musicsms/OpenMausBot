import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/network/sse_client.dart';
import 'package:mobile/core/storage/pairing_storage.dart';
import 'package:mobile/core/theme/grok_theme.dart';
import 'package:mobile/features/approvals/approval_card.dart';
import 'package:mobile/features/approvals/approval_model.dart';
import 'package:mobile/features/pairing/pairing_model.dart';

class _RealHttpOverrides extends HttpOverrides {}

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
}
