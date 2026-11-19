import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile/core/e2e/descriptor.dart';
import 'package:mobile/core/network/sse_client.dart';
import 'package:mobile/core/storage/pairing_storage.dart';
import 'package:mobile/features/pairing/pairing_model.dart';
import 'package:mobile/features/pairing/pairing_view.dart';

void main() {
  group('PairingPayload', () {
    test('PairingPayload parses JSON QR code payload correctly', () {
      const rawJson =
          '{"host":"192.168.1.50","port":8810,"remoteUrl":"https://omb.tailscale:8810","pairingSecret":"sec123","machineName":"Studio"}';
      final payload = PairingPayload.fromJsonString(rawJson);
      expect(payload.host, '192.168.1.50');
      expect(payload.port, 8810);
      expect(payload.remoteUrl, 'https://omb.tailscale:8810');
      expect(payload.credential, 'sec123');
      expect(payload.pairingSecret, 'sec123');
      expect(payload.machineName, 'Studio');
      expect(payload.lanUrl, 'http://192.168.1.50:8810');
      expect(payload.endpoints.map((e) => e.kind).toList(), ['lan', 'hosted']);
    });

    test('PairingPayload falls back to default machine name when omitted', () {
      const rawJson =
          '{"host":"10.0.0.5","port":8810,"pairingSecret":"sec456"}';
      final payload = PairingPayload.fromJsonString(rawJson);
      expect(payload.host, '10.0.0.5');
      expect(payload.port, 8810);
      expect(payload.remoteUrl, isNull);
      expect(payload.credential, 'sec456');
      expect(payload.machineName, 'OpenMausBot Desktop');
      expect(payload.lanUrl, 'http://10.0.0.5:8810');
    });

    test('PairingPayload parses openmausbot://pair URI format', () {
      const rawUri =
          'openmausbot://pair?address=192.168.1.80:8810&token=omb_pair_secret789&name=HomeServer&remoteUrl=https%3A%2F%2Fremote.omb%3A8810';
      final payload = PairingPayload.fromJsonString(rawUri);
      expect(payload.host, '192.168.1.80');
      expect(payload.port, 8810);
      expect(payload.remoteUrl, 'https://remote.omb:8810');
      expect(payload.credential, 'omb_pair_secret789');
      expect(payload.machineName, 'HomeServer');
      expect(payload.lanUrl, 'http://192.168.1.80:8810');
    });

    test('PairingPayload decodes endpoints query param', () {
      final endpointsJson = jsonEncode([
        {'url': 'https://c-abc.openmausbot.com', 'kind': 'hosted', 'priority': 0},
        {'url': 'http://192.168.1.9:8810', 'kind': 'lan', 'priority': 200},
      ]);
      final encoded = base64Url.encode(utf8.encode(endpointsJson)).replaceAll('=', '');
      final rawUri =
          'openmausbot://pair?address=192.168.1.9:8810&token=omb_pair_${'a' * 43}&name=Desk&endpoints=$encoded';
      final payload = PairingPayload.fromJsonString(rawUri);
      expect(payload.endpoints.length, 2);
      expect(payload.endpoints.first.kind, 'hosted');
      expect(payload.dialUrl, 'https://c-abc.openmausbot.com');
    });

    test('PairingPayload extracts e2e query parameter from openmausbot://pair URI', () {
      final desc = E2EDescriptor.parseJson({
        'v': 1,
        'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
        'h': 'lz81isB3BuNV6rHgYgG3Wg',
        'r': ['relay.example.com'],
      });
      final rawUri =
          'openmausbot://pair?address=192.168.1.80:8810&token=omb_pair_secret789&name=HomeServer&e2e=${desc.toB64u()}';
      final payload = PairingPayload.fromJsonString(rawUri);
      expect(payload.e2e, isNotNull);
      expect(payload.e2e!.k, desc.k);
      expect(payload.e2e!.h, desc.h);
      expect(payload.e2e!.relayNodes, ['relay.example.com']);
    });
  });

  group('PairingStorage', () {
    test('PairingStorage saves and reads device credentials and endpoints', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = PairingStorage();
      await storage.saveDeviceToken('omb_tok-abc');
      await storage.saveEndpoints(endpoints: const [
        CompanionEndpoint(url: 'http://192.168.1.50:8810', kind: 'lan', priority: 200),
        CompanionEndpoint(url: 'https://c-hosted.openmausbot.com', kind: 'hosted', priority: 0),
      ]);

      expect(await storage.getDeviceToken(), 'omb_tok-abc');
      expect(await storage.getLanUrl(), 'http://192.168.1.50:8810');
      expect(await storage.getRemoteUrl(), 'https://c-hosted.openmausbot.com');
      expect((await storage.getEndpoints()).length, 2);
    });

    test('PairingStorage clear wipes all credentials', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = PairingStorage();
      await storage.saveDeviceToken('omb_tok-abc');
      await storage.saveEndpoints(lanUrl: 'http://192.168.1.50:8810');
      await storage.clear();

      expect(await storage.getDeviceToken(), isNull);
      expect(await storage.getLanUrl(), isNull);
      expect(await storage.getRemoteUrl(), isNull);
      expect(await storage.getEndpoints(), isEmpty);
    });

    test('PairingStorage stores and retrieves pinned transport key k, h, and r', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = PairingStorage();
      await storage.saveE2EIdentity(
        transportPublicKey: 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
        hostId: 'lz81isB3BuNV6rHgYgG3Wg',
        relayNodes: ['relay1.example.com', 'relay2.example.com'],
      );

      final identity = await storage.getE2EIdentity();
      expect(identity, isNotNull);
      expect(identity!.k, 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0');
      expect(identity.h, 'lz81isB3BuNV6rHgYgG3Wg');
      expect(identity.r, ['relay1.example.com', 'relay2.example.com']);

      await storage.clearE2EIdentity();
      expect(await storage.getE2EIdentity(), isNull);
    });
  });

  group('SseNetworkClient E2E fail-closed', () {
    test('SseNetworkClient refuses plain HTTP requests when an E2E pairing exists (fail-closed invariant)', () async {
      var plainHttpCalled = false;
      final mockHttp = MockClient((request) async {
        plainHttpCalled = true;
        return http.Response('{"app":"openmausbot"}', 200);
      });

      final desc = E2EDescriptor.parseJson({
        'v': 1,
        'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
        'h': 'lz81isB3BuNV6rHgYgG3Wg',
        'r': ['relay.example.com'],
      });

      final sseClient = SseNetworkClient(
        deviceToken: 'omb_test_tok',
        lanUrl: 'http://192.168.1.50:8810',
        e2e: desc,
        httpClient: mockHttp,
        connector: (uri, {protocols}) async {
          throw const SocketException('Relay connection failed');
        },
      );

      expect(sseClient.isE2E, isTrue);
      expect(() => sseClient.resolveActiveBaseUrl(), throwsA(isA<Exception>()));
      expect(plainHttpCalled, isFalse);
    });
  });

  group('PairingView', () {
    testWidgets('renders QR container with MobileScanner by default',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            onPairSuccess: (_) async {},
            onManualCodeSubmit: (_) async {},
          ),
        ),
      );

      expect(find.text('Pair with Desktop'), findsOneWidget);
      expect(find.byType(MobileScanner), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('Connect with Code'), findsOneWidget);
    });

    testWidgets('renders custom scanner widget when provided',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            scannerWidget: const Icon(Icons.qr_code_scanner),
            onPairSuccess: (_) async {},
            onManualCodeSubmit: (_) async {},
          ),
        ),
      );

      expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
    });

    testWidgets('submits host + 6-digit code on manual button tap',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ManualPairRequest? submitted;
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            onPairSuccess: (_) async {},
            onManualCodeSubmit: (request) async {
              submitted = request;
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).first, '192.168.1.40');
      await tester.enterText(find.byType(TextField).last, '123456');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();

      expect(submitted, isNotNull);
      expect(submitted!.code, '123456');
      expect(submitted!.host, '192.168.1.40');
      expect(submitted!.baseUrl, 'http://192.168.1.40:8810');
    });

    testWidgets('does not submit without host or full code',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ManualPairRequest? submitted;
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            onPairSuccess: (_) async {},
            onManualCodeSubmit: (request) async {
              submitted = request;
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).last, '123');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();
      expect(submitted, isNull);

      await tester.enterText(find.byType(TextField).last, '123456');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();
      expect(submitted, isNull);
    });

    testWidgets('filters non-digit characters in code TextField',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            onPairSuccess: (_) async {},
            onManualCodeSubmit: (_) async {},
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).last, 'ab12cd34');
      await tester.pump();

      expect(find.text('1234'), findsOneWidget);
    });

    testWidgets('processes scanned QR payload when scanner triggers callback',
        (WidgetTester tester) async {
      PairingPayload? capturedPayload;
      final viewKey = GlobalKey<PairingViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            key: viewKey,
            onPairSuccess: (payload) async {
              capturedPayload = payload;
            },
            onManualCodeSubmit: (_) async {},
          ),
        ),
      );

      const rawJson =
          '{"host":"192.168.1.50","port":8810,"remoteUrl":"https://omb.tailscale:8810","pairingSecret":"sec123","machineName":"Studio"}';
      await viewKey.currentState!.handleScannedPayload(rawJson);

      expect(capturedPayload, isNotNull);
      expect(capturedPayload!.host, '192.168.1.50');
      expect(capturedPayload!.machineName, 'Studio');
    });
  });
}
