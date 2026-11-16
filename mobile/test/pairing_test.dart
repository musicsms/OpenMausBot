import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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
      expect(payload.pairingSecret, 'sec123');
      expect(payload.machineName, 'Studio');
      expect(payload.lanUrl, 'http://192.168.1.50:8810');
    });

    test('PairingPayload falls back to default machine name when omitted', () {
      const rawJson =
          '{"host":"10.0.0.5","port":8810,"pairingSecret":"sec456"}';
      final payload = PairingPayload.fromJsonString(rawJson);
      expect(payload.host, '10.0.0.5');
      expect(payload.port, 8810);
      expect(payload.remoteUrl, isNull);
      expect(payload.pairingSecret, 'sec456');
      expect(payload.machineName, 'OpenMausBot Desktop');
      expect(payload.lanUrl, 'http://10.0.0.5:8810');
    });
  });

  group('PairingStorage', () {
    test('PairingStorage saves and reads device credentials', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = PairingStorage();
      await storage.saveDeviceToken('tok-abc');
      await storage.saveEndpoints(
        lanUrl: 'http://192.168.1.50:8810',
        remoteUrl: 'https://omb.tailscale:8810',
      );

      expect(await storage.getDeviceToken(), 'tok-abc');
      expect(await storage.getLanUrl(), 'http://192.168.1.50:8810');
      expect(await storage.getRemoteUrl(), 'https://omb.tailscale:8810');
    });

    test('PairingStorage clear wipes all credentials', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = PairingStorage();
      await storage.saveDeviceToken('tok-abc');
      await storage.saveEndpoints(lanUrl: 'http://192.168.1.50:8810');
      await storage.clear();

      expect(await storage.getDeviceToken(), isNull);
      expect(await storage.getLanUrl(), isNull);
      expect(await storage.getRemoteUrl(), isNull);
    });
  });

  group('PairingView', () {
    testWidgets('renders QR container with MobileScanner by default',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            onPairSuccess: (_) {},
            onManualCodeSubmit: (_) {},
          ),
        ),
      );

      expect(find.text('Pair with Desktop'), findsOneWidget);
      expect(find.byType(MobileScanner), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Connect with Code'), findsOneWidget);
    });

    testWidgets('renders custom scanner widget when provided',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            scannerWidget: const Icon(Icons.qr_code_scanner),
            onPairSuccess: (_) {},
            onManualCodeSubmit: (_) {},
          ),
        ),
      );

      expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
    });

    testWidgets('submits 6-digit code on manual button tap',
        (WidgetTester tester) async {
      String? submittedCode;
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            onPairSuccess: (_) {},
            onManualCodeSubmit: (code) {
              submittedCode = code;
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Connect with Code'));
      await tester.pump();

      expect(submittedCode, '123456');
    });

    testWidgets('does not submit code if length is not 6',
        (WidgetTester tester) async {
      String? submittedCode;
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            onPairSuccess: (_) {},
            onManualCodeSubmit: (code) {
              submittedCode = code;
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '123');
      await tester.tap(find.text('Connect with Code'));
      await tester.pump();

      expect(submittedCode, isNull);
    });

    testWidgets('filters non-digit characters in code TextField',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PairingView(
            onPairSuccess: (_) {},
            onManualCodeSubmit: (_) {},
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'ab12cd34');
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
            onPairSuccess: (payload) {
              capturedPayload = payload;
            },
            onManualCodeSubmit: (_) {},
          ),
        ),
      );

      const rawJson =
          '{"host":"192.168.1.50","port":8810,"remoteUrl":"https://omb.tailscale:8810","pairingSecret":"sec123","machineName":"Studio"}';
      viewKey.currentState!.handleScannedPayload(rawJson);

      expect(capturedPayload, isNotNull);
      expect(capturedPayload!.host, '192.168.1.50');
      expect(capturedPayload!.machineName, 'Studio');
    });
  });
}
