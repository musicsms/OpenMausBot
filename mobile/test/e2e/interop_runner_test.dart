import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nibble/core/e2e/descriptor.dart';
import 'package:nibble/core/e2e/relay_client.dart';
import 'package:nibble/core/network/sse_client.dart';
import 'package:nibble/core/storage/pairing_storage.dart';
import 'package:nibble/features/pairing/pairing_model.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  test('self-hosted relay companion end-to-end interop', () async {
    final pairingUri = Platform.environment['PAIRING_URI'];
    final relayUrl = Platform.environment['OMB_RELAY_URL'];
    final syncDir = Platform.environment['SYNC_DIR'];

    if (pairingUri == null || relayUrl == null || syncDir == null) {
      return;
    }

    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);

    final payload = PairingPayload.fromJsonString(pairingUri);
    expect(payload.e2e, isNotNull);
    final desc = payload.e2e!;
    expect(desc.k, isNotEmpty);
    expect(desc.hasRelay, isTrue);

    FlutterSecureStorage.setMockInitialValues({});
    final storage = PairingStorage();

    Future<RelayWebSocket> loopbackConnector(Uri uri, {Iterable<String>? protocols}) async {
      final override = Uri.parse(relayUrl);
      final targetUri = Uri.parse('${override.scheme}://${override.host}:${override.port}${uri.path}');
      final ws = await WebSocket.connect(targetUri.toString(), protocols: protocols);
      return IORelayWebSocket(ws);
    }

    final pairResult = await SseNetworkClient.redeemPair(
      deviceName: 'Dart Interop Client',
      credential: payload.credential,
      e2e: desc,
      connector: loopbackConnector,
    );

    expect(pairResult.token, startsWith('omb_'));
    expect(pairResult.e2e, isNotNull);

    await storage.saveDeviceToken(pairResult.token);
    await storage.saveE2EIdentity(
      transportPublicKey: pairResult.e2e!.k,
      hostId: pairResult.e2e!.h,
      relayNodes: pairResult.e2e!.relayNodes,
    );

    final pinned = await storage.getE2EIdentity();
    expect(pinned, isNotNull);
    expect(pinned!.k, desc.k);

    final pairedFile = File('$syncDir/paired.json');
    await pairedFile.writeAsString(jsonEncode({
      'token': pairResult.token,
      'deviceId': pairResult.deviceId,
    }));

    final storedDesc = await storage.getE2EDescriptor();
    expect(storedDesc, isNotNull);

    final sseClient = SseNetworkClient(
      deviceToken: (await storage.getDeviceToken())!,
      e2e: storedDesc,
      connector: loopbackConnector,
    );

    expect(sseClient.isE2E, isTrue);

    final bots = await sseClient.listBots();
    expect(bots, isNotEmpty);
    final botId = bots.first['id'] as String;

    final eventCompleter = Completer<CompanionEvent>();
    final sub = sseClient.streamEvents().listen(
      (event) {
        if (!eventCompleter.isCompleted) {
          eventCompleter.complete(event);
        }
      },
    );

    final sendOk = await sseClient.sendBotMessage(
      botId: botId,
      text: 'hello from dart client over self-hosted relay',
    );
    expect(sendOk, isTrue);

    final firstEvent = await eventCompleter.future.timeout(const Duration(seconds: 10));
    expect(firstEvent, isNotNull);

    await sseClient.respondApproval(
      botId: botId,
      threadId: 'interop-thread',
      requestId: 'req-interop-approval',
      behavior: 'allow',
    );

    final readyFile = File('$syncDir/ready_for_revocation');
    await readyFile.writeAsString('ready');

    final revokedFile = File('$syncDir/revoked');
    var waited = 0;
    while (!revokedFile.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      waited += 100;
      if (waited > 20000) {
        throw TimeoutException('Timed out waiting for revocation signal');
      }
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));

    var removedWaited = 0;
    while (!sseClient.isDeviceRemoved && removedWaited < 3000) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      removedWaited += 50;
    }
    expect(sseClient.isDeviceRemoved, isTrue);

    final postRevokeClient = PhoneRelayClient(
      descriptor: storedDesc!,
      credentialToken: pairResult.token,
      connector: loopbackConnector,
      timeout: const Duration(seconds: 3),
    );

    var failedWithExpectedCode = false;
    try {
      await postRevokeClient.connect();
    } on RelayException catch (e) {
      if (e.code == 4404 || e.code == 4001) {
        failedWithExpectedCode = true;
      }
    } catch (_) {}

    expect(failedWithExpectedCode, isTrue);

    await sub.cancel();
    sseClient.close();
    postRevokeClient.close();

    final doneFile = File('$syncDir/done');
    await doneFile.writeAsString('done');
  });
}
