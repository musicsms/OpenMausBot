import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/storage/pairing_storage.dart';
import 'package:mobile/features/chat/chat_view.dart';
import 'package:mobile/features/pairing/pairing_view.dart';
import 'package:mobile/main.dart';

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
  });

  testWidgets('displays ChatView when device token exists in storage', (WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'omb_device_token': 'existing-token-xyz',
      'omb_lan_url': 'http://127.0.0.1:8810',
    });
    final storage = PairingStorage();

    await tester.pumpWidget(
      MausBotApp(
        storage: storage,
        scannerWidget: const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(PairingView), findsNothing);
    expect(find.text('OpenMausBot'), findsOneWidget);
  });

  testWidgets('transitions to ChatView on manual code submit', (WidgetTester tester) async {
    final storage = PairingStorage();
    await tester.pumpWidget(
      MausBotApp(
        storage: storage,
        scannerWidget: const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PairingView), findsOneWidget);

    await tester.enterText(find.byType(TextField), '654321');
    await tester.tap(find.text('Connect with Code'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(PairingView), findsNothing);
    expect(await storage.getDeviceToken(), '654321');
  });

  testWidgets('transitions to ChatView on QR pair success', (WidgetTester tester) async {
    final storage = PairingStorage();
    final pairingKey = GlobalKey<PairingViewState>();

    await tester.pumpWidget(
      MausBotApp(
        storage: storage,
        scannerWidget: SizedBox(key: pairingKey),
      ),
    );
    await tester.pumpAndSettle();

    final pairingViewFinder = find.byType(PairingView);
    expect(pairingViewFinder, findsOneWidget);
    final pairingViewState = tester.state<PairingViewState>(pairingViewFinder);

    const qrJson =
        '{"host":"192.168.1.88","port":8810,"remoteUrl":"https://omb.remote","pairingSecret":"sec-qr-777","machineName":"Laptop"}';
    pairingViewState.handleScannedPayload(qrJson);
    await tester.pumpAndSettle();

    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(PairingView), findsNothing);
    expect(await storage.getDeviceToken(), 'sec-qr-777');
    expect(await storage.getLanUrl(), 'http://192.168.1.88:8810');
    expect(await storage.getRemoteUrl(), 'https://omb.remote');
  });
}
