import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/storage/pairing_storage.dart';
import 'package:mobile/features/chat/chat_view.dart';
import 'package:mobile/features/pairing/pairing_view.dart';
import 'package:mobile/main.dart';

MockClient _pairMock({
  required String token,
  String lanUrl = 'http://192.168.1.88:8810',
  String? remoteUrl,
}) {
  return MockClient((request) async {
    if (request.url.path == '/api/pair' && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['deviceName'], isA<String>());
      expect(body.containsKey('credential') || body.containsKey('code'), isTrue);
      return http.Response(
        jsonEncode({
          'token': token,
          'device': {'id': 'd1', 'name': body['deviceName']},
          'serverName': 'Laptop',
          'endpoints': [
            {'url': lanUrl, 'kind': 'lan', 'priority': 200},
            if (remoteUrl != null)
              {'url': remoteUrl, 'kind': 'hosted', 'priority': 0},
          ],
        }),
        201,
      );
    }
    if (request.url.path == '/api/health') {
      return http.Response('{"app":"openmausbot"}', 200);
    }
    if (request.url.path == '/api/bots') {
      return http.Response(
        jsonEncode([
          {'id': 'bot-main', 'name': 'Main', 'threadId': 'thread-main'},
        ]),
        200,
      );
    }
    if (request.url.path == '/api/events') {
      return http.Response(
        'data: {"kind":"hello","cursor":"a:0"}\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    return http.Response('{"ok":true}', 200);
  });
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('displays PairingView when unauthenticated', (WidgetTester tester) async {
    final storage = PairingStorage();
    await tester.pumpWidget(
      MausBotApp(
        storage: storage,
        scannerWidget: const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PairingView), findsOneWidget);
    expect(find.byType(ChatView), findsNothing);
    expect(find.text('Pair with Desktop'), findsOneWidget);
    expect(find.textContaining('desktop-host'), findsOneWidget);
  });

  testWidgets('displays ChatView when device token exists in storage', (WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'omb_device_token': 'omb_existing-token-xyz',
      'omb_lan_url': 'http://127.0.0.1:8810',
    });
    final storage = PairingStorage();

    await tester.pumpWidget(
      MausBotApp(
        storage: storage,
        scannerWidget: const SizedBox(),
        httpClient: _pairMock(token: 'omb_existing-token-xyz', lanUrl: 'http://127.0.0.1:8810'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(PairingView), findsNothing);
    expect(find.text('OpenMausBot'), findsOneWidget);
  });

  testWidgets('manual code redeem stores omb_ token and opens chat', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final storage = PairingStorage();
    const token = 'omb_manual_token_abcdefghijklmnopqrstuvw';
    await tester.pumpWidget(
      MausBotApp(
        storage: storage,
        scannerWidget: const SizedBox(),
        httpClient: _pairMock(token: token, lanUrl: 'http://192.168.1.50:8810'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PairingView), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '192.168.1.50');
    await tester.enterText(find.byType(TextField).last, '654321');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(PairingView), findsNothing);
    expect(await storage.getDeviceToken(), token);
    expect(await storage.getDeviceToken(), isNot('654321'));
    expect(await storage.getLanUrl(), 'http://192.168.1.50:8810');
  });

  testWidgets('QR pair redeem stores omb_ token not the pairing secret', (WidgetTester tester) async {
    final storage = PairingStorage();
    const token = 'omb_qr_token_abcdefghijklmnopqrstuvwxyz12';

    await tester.pumpWidget(
      MausBotApp(
        storage: storage,
        scannerWidget: const SizedBox(),
        httpClient: _pairMock(
          token: token,
          lanUrl: 'http://192.168.1.88:8810',
          remoteUrl: 'https://c-hosted.openmausbot.com',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pairingViewFinder = find.byType(PairingView);
    expect(pairingViewFinder, findsOneWidget);
    final pairingViewState = tester.state<PairingViewState>(pairingViewFinder);

    const qrJson =
        '{"host":"192.168.1.88","port":8810,"remoteUrl":"https://c-hosted.openmausbot.com","pairingSecret":"sec-qr-777","machineName":"Laptop"}';
    await pairingViewState.handleScannedPayload(qrJson);
    await tester.pumpAndSettle();

    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(PairingView), findsNothing);
    expect(await storage.getDeviceToken(), token);
    expect(await storage.getDeviceToken(), isNot('sec-qr-777'));
    expect(await storage.getLanUrl(), 'http://192.168.1.88:8810');
    expect(await storage.getRemoteUrl(), 'https://c-hosted.openmausbot.com');
  });
}
