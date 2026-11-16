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
  test('E2E Flow: Pair device -> Store credentials -> Stream messages via dual route', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = PairingStorage();

    const qrPayload = '{"host":"127.0.0.1","port":8810,"remoteUrl":null,"pairingSecret":"sec","machineName":"Studio"}';
    final payload = PairingPayload.fromJsonString(qrPayload);

    await storage.saveDeviceToken('tok-123');
    await storage.saveEndpoints(lanUrl: payload.lanUrl);

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/healthz') {
        return http.Response('{"status":"ok"}', 200);
      }
      if (request.url.path.contains('/messages')) {
        return http.Response('data: Chunky response\n\n', 200, headers: {'content-type': 'text/event-stream'});
      }
      return http.Response('OK', 200);
    });

    final sseClient = SseNetworkClient(
      lanUrl: (await storage.getLanUrl())!,
      deviceToken: (await storage.getDeviceToken())!,
      httpClient: mockHttp,
    );

    final streamOutput = await sseClient.streamMessages('thread-main').first;
    expect(streamOutput, 'Chunky response');
  });

  test('E2E Flow: Dual-route failover to remote endpoint when LAN health check fails', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = PairingStorage();

    const qrPayload =
        '{"host":"192.168.1.100","port":8810,"remoteUrl":"https://omb.remote:8810","pairingSecret":"sec-remote","machineName":"Studio"}';
    final payload = PairingPayload.fromJsonString(qrPayload);

    await storage.saveDeviceToken('remote-device-tok');
    await storage.saveEndpoints(lanUrl: payload.lanUrl, remoteUrl: payload.remoteUrl);

    final mockHttp = MockClient((request) async {
      if (request.url.host == '192.168.1.100') {
        return http.Response('Connection refused', 503);
      }
      if (request.url.host == 'omb.remote' && request.url.path == '/healthz') {
        return http.Response('{"status":"ok"}', 200);
      }
      if (request.url.host == 'omb.remote' && request.url.path.contains('/messages')) {
        return http.Response('data: Remote fallback stream\n\n', 200, headers: {'content-type': 'text/event-stream'});
      }
      return http.Response('Not found', 404);
    });

    final sseClient = SseNetworkClient(
      lanUrl: (await storage.getLanUrl())!,
      remoteUrl: await storage.getRemoteUrl(),
      deviceToken: (await storage.getDeviceToken())!,
      httpClient: mockHttp,
    );

    final activeUrl = await sseClient.resolveActiveBaseUrl();
    expect(activeUrl, 'https://omb.remote:8810');

    final message = await sseClient.streamMessages('thread-remote').first;
    expect(message, 'Remote fallback stream');
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

  test('E2E Flow: Live fake companion process serves health, pairing, and SSE messages', () async {
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);

    final process = await Process.start(
      'node',
      ['--experimental-strip-types', 'test/fixtures/fake-companion.ts'],
      environment: {'PORT': '0'},
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

      final qrPayload = '{"host":"127.0.0.1","port":$port,"pairingSecret":"test-secret","machineName":"Studio"}';
      final payload = PairingPayload.fromJsonString(qrPayload);

      final pairResponse = await http.post(
        Uri.parse('$baseUrl/api/pair'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'pairingSecret': payload.pairingSecret}),
      );
      expect(pairResponse.statusCode, 200);
      final pairBody = jsonDecode(pairResponse.body) as Map<String, dynamic>;
      final deviceToken = pairBody['deviceToken'] as String;
      expect(deviceToken, 'mock-device-token-12345');

      await storage.saveDeviceToken(deviceToken);
      await storage.saveEndpoints(lanUrl: baseUrl);

      final sseClient = SseNetworkClient(
        lanUrl: (await storage.getLanUrl())!,
        deviceToken: (await storage.getDeviceToken())!,
      );

      final messages = await sseClient.streamMessages('main-thread').toList();
      expect(messages, [
        'Xin chào! Tôi là OpenMausBot trên mobile.',
        'Đang chuẩn bị thực hiện task...',
      ]);
    } finally {
      process.kill();
      await process.exitCode;
    }
  });
}
