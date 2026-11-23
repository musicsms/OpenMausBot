import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nibble/core/e2e/credentials.dart';
import 'package:nibble/core/e2e/crypto.dart';
import 'package:nibble/core/e2e/descriptor.dart';
import 'package:nibble/core/e2e/noise.dart';
import 'package:nibble/core/e2e/relay_client.dart';
import 'package:nibble/core/e2e/yamux.dart';

class MockRelayWebSocket implements RelayWebSocket {
  final StreamController<dynamic> _incoming = StreamController<dynamic>.broadcast();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>.broadcast();
  int? _closeCode;
  String? _closeReason;
  bool _isClosed = false;

  Stream<dynamic> get outgoing => _outgoing.stream;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void add(dynamic data) {
    if (!_isClosed) {
      _outgoing.add(data);
    }
  }

  void deliver(dynamic message) {
    if (!_isClosed) {
      _incoming.add(message);
    }
  }

  void deliverClose(int code, [String? reason]) {
    _closeCode = code;
    _closeReason = reason;
    _isClosed = true;
    _incoming.close();
  }

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_isClosed) return;
    _closeCode = code;
    _closeReason = reason;
    _isClosed = true;
    await _incoming.close();
    await _outgoing.close();
  }
}

void main() {
  final vectorFile = File('../companion/src/e2e/vectors/v1.json');
  final vectors = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;

  final transportPubHex = vectors['V1']['transportPublic'] as String;
  final transportPubBytes = Uint8List.fromList(hex.decode(transportPubHex));
  final transportPrivHex = vectors['inputs']['transportPrivate'] as String;
  final transportPrivBytes = Uint8List.fromList(hex.decode(transportPrivHex));
  final hostIdHex = vectors['inputs']['hostId'] as String;
  final hostIdBytes = Uint8List.fromList(hex.decode(hostIdHex));
  final pskHex = vectors['V1']['credentials'][0]['psk'] as String;
  final pskBytes = Uint8List.fromList(hex.decode(pskHex));
  final admHex = vectors['V1']['credentials'][0]['adm'] as String;
  final admBytes = Uint8List.fromList(hex.decode(admHex));

  final validDescriptor = E2EDescriptor(
    version: 1,
    k: b64u(transportPubBytes),
    transportPublicKey: transportPubBytes,
    h: b64u(hostIdBytes),
    hostId: hostIdBytes,
    relayNodes: ['relay1.example.com', 'relay2.example.com'],
  );

  group('PhoneRelayClient', () {
    test('connects to relay, performs handshake and transmits HTTP request over yamux', () async {
      late MockRelayWebSocket mockSocket;
      final connectedUris = <Uri>[];
      final connectedProtocols = <Iterable<String>?>[];

      Future<RelayWebSocket> testConnector(Uri uri, {Iterable<String>? protocols}) async {
        connectedUris.add(uri);
        connectedProtocols.add(protocols);
        mockSocket = MockRelayWebSocket();

        unawaited(() async {
          final outStream = mockSocket.outgoing;
          await for (final item in outStream) {
            if (item is String) {
              final parsed = jsonDecode(item) as Map<String, dynamic>;
              if (parsed['t'] == 'phone') {
                expect(parsed['v'], equals(1));
                expect(parsed['hid'], equals(b64u(hostIdBytes)));
                expect(parsed['adm'], equals(b64u(admBytes)));
                mockSocket.deliver(jsonEncode({'t': 'ready'}));
              }
            } else if (item is List<int>) {
              final msg1 = Uint8List.fromList(item);
              final computerEphemeral = P256.generateKeyPair();
              final serverSymmetric = SymmetricState.initialize();
              serverSymmetric.mixHash(prologue(transportRelay));
              serverSymmetric.mixHash(transportPubBytes);
              serverSymmetric.mixKeyAndHash(pskBytes);

              final phoneEphemeralPub = Uint8List.sublistView(msg1, 0, publicKeyBytes);
              serverSymmetric.mixHash(phoneEphemeralPub);
              serverSymmetric.mixKey(phoneEphemeralPub);

              final es = P256.computeSecret(transportPrivBytes, phoneEphemeralPub);
              serverSymmetric.mixKey(es);

              final msg1Payload = serverSymmetric.decryptAndHash(Uint8List.sublistView(msg1, publicKeyBytes));
              final payload1Json = jsonDecode(utf8.decode(msg1Payload)) as Map<String, dynamic>;
              final connB64 = payload1Json['conn'] as String;

              serverSymmetric.mixHash(computerEphemeral.publicKey);
              serverSymmetric.mixKey(computerEphemeral.publicKey);

              final ee = P256.computeSecret(computerEphemeral.privateKey, phoneEphemeralPub);
              serverSymmetric.mixKey(ee);

              final payload2 = Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'conn': connB64})));
              final encPayload2 = serverSymmetric.encryptAndHash(payload2);

              final msg2 = Uint8List(publicKeyBytes + encPayload2.length);
              msg2.setRange(0, publicKeyBytes, computerEphemeral.publicKey);
              msg2.setRange(publicKeyBytes, msg2.length, encPayload2);

              final splitCiphers = serverSymmetric.split();
              final serverReceiveCipher = RecordCipher(splitCiphers[0]);
              final serverSendCipher = RecordCipher(splitCiphers[1]);

              late final YamuxSession serverMux;
              serverMux = YamuxSession(
                role: YamuxRole.computer,
                onSend: (frame) {
                  final record = serverSendCipher.seal(frame.encode());
                  mockSocket.deliver(record);
                },
                onOpened: (streamId) {
                  serverMux.accept(streamId);
                  final stream = serverMux.getStream(streamId)!;
                  final buffer = <int>[];
                  stream.listen((data) {
                    buffer.addAll(data);
                  }, onDone: () {
                    final reqText = utf8.decode(buffer);
                    if (reqText.contains('GET /api/health HTTP/1.1')) {
                      const res =
                          'HTTP/1.1 200 OK\r\n'
                          'Content-Type: application/json\r\n'
                          'Content-Length: 15\r\n'
                          '\r\n'
                          '{"status":"ok"}';
                      stream.add(utf8.encode(res));
                      stream.finish();
                    }
                  });
                },
              );

              mockSocket.outgoing.listen((encItem) {
                if (encItem is List<int>) {
                  try {
                    final dec = serverReceiveCipher.open(Uint8List.fromList(encItem));
                    serverMux.receive(YamuxFrame.decode(dec));
                  } catch (_) {}
                }
              });

              mockSocket.deliver(msg2);
              break;
            }
          }
        }());

        return mockSocket;
      }

      final client = PhoneRelayClient(
        descriptor: validDescriptor,
        psk: pskBytes,
        adm: admBytes,
        connector: testConnector,
      );

      await client.connect();

      expect(client.isConnected, isTrue);
      expect(client.status, equals(RelayClientStatus.connected));
      expect(client.connectedNode, equals('relay1.example.com'));
      expect(connectedUris.first.toString(), equals('wss://relay1.example.com/v1/phone'));
      expect(connectedProtocols.first, contains('omb-relay.v1'));

      final req = http.Request('GET', Uri.parse('http://phone-relay.invalid/api/health'));
      final response = await client.httpClient.send(req);

      expect(response.statusCode, equals(200));
      expect(await response.stream.bytesToString(), equals('{"status":"ok"}'));

      await client.close();
      expect(client.status, equals(RelayClientStatus.closed));
    });

    test('falls back to next node when first node returns 4404', () async {
      final dialedNodes = <String>[];

      Future<RelayWebSocket> failoverConnector(Uri uri, {Iterable<String>? protocols}) async {
        final node = uri.host;
        dialedNodes.add(node);
        final socket = MockRelayWebSocket();

        if (node == 'relay1.example.com') {
          unawaited(() async {
            await for (final item in socket.outgoing) {
              if (item is String) {
                socket.deliverClose(4404, 'computer not connected here');
                break;
              }
            }
          }());
        } else if (node == 'relay2.example.com') {
          unawaited(() async {
            await for (final item in socket.outgoing) {
              if (item is String) {
                socket.deliver(jsonEncode({'t': 'ready'}));
              } else if (item is List<int>) {
                final msg1 = Uint8List.fromList(item);
                final computerEphemeral = P256.generateKeyPair();
                final serverSymmetric = SymmetricState.initialize();
                serverSymmetric.mixHash(prologue(transportRelay));
                serverSymmetric.mixHash(transportPubBytes);
                serverSymmetric.mixKeyAndHash(pskBytes);

                final phoneEphemeralPub = Uint8List.sublistView(msg1, 0, publicKeyBytes);
                serverSymmetric.mixHash(phoneEphemeralPub);
                serverSymmetric.mixKey(phoneEphemeralPub);

                final es = P256.computeSecret(transportPrivBytes, phoneEphemeralPub);
                serverSymmetric.mixKey(es);

                final msg1Payload = serverSymmetric.decryptAndHash(Uint8List.sublistView(msg1, publicKeyBytes));
                final payload1Json = jsonDecode(utf8.decode(msg1Payload)) as Map<String, dynamic>;
                final connB64 = payload1Json['conn'] as String;

                serverSymmetric.mixHash(computerEphemeral.publicKey);
                serverSymmetric.mixKey(computerEphemeral.publicKey);

                final ee = P256.computeSecret(computerEphemeral.privateKey, phoneEphemeralPub);
                serverSymmetric.mixKey(ee);

                final payload2 = Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'conn': connB64})));
                final encPayload2 = serverSymmetric.encryptAndHash(payload2);

                final msg2 = Uint8List(publicKeyBytes + encPayload2.length);
                msg2.setRange(0, publicKeyBytes, computerEphemeral.publicKey);
                msg2.setRange(publicKeyBytes, msg2.length, encPayload2);

                socket.deliver(msg2);
                break;
              }
            }
          }());
        }

        return socket;
      }

      final client = PhoneRelayClient(
        descriptor: validDescriptor,
        psk: pskBytes,
        adm: admBytes,
        connector: failoverConnector,
      );

      await client.connect();

      expect(client.isConnected, isTrue);
      expect(client.connectedNode, equals('relay2.example.com'));
      expect(dialedNodes, equals(['relay1.example.com', 'relay2.example.com']));

      await client.close();
    });

    test('sets status to offline and reports computer asleep or offline when all nodes return 4404', () async {
      Future<RelayWebSocket> all4404Connector(Uri uri, {Iterable<String>? protocols}) async {
        final socket = MockRelayWebSocket();
        unawaited(() async {
          await for (final item in socket.outgoing) {
            if (item is String) {
              socket.deliverClose(4404, 'computer not connected');
              break;
            }
          }
        }());
        return socket;
      }

      final client = PhoneRelayClient(
        descriptor: validDescriptor,
        psk: pskBytes,
        adm: admBytes,
        connector: all4404Connector,
      );

      await expectLater(
        client.connect(),
        throwsA(
          isA<RelayOfflineException>()
              .having((e) => e.message, 'message', contains('computer asleep or offline'))
              .having((e) => e.code, 'code', equals(4404)),
        ),
      );

      expect(client.status, equals(RelayClientStatus.offline));
      expect(client.isOffline, isTrue);
      expect(client.errorMessage, contains('computer asleep or offline'));
    });

    test('handles 4401 host token invalid close code', () async {
      Future<RelayWebSocket> unauthConnector(Uri uri, {Iterable<String>? protocols}) async {
        final socket = MockRelayWebSocket();
        unawaited(() async {
          await for (final item in socket.outgoing) {
            if (item is String) {
              socket.deliverClose(4401, 'host token invalid');
              break;
            }
          }
        }());
        return socket;
      }

      final client = PhoneRelayClient(
        descriptor: validDescriptor,
        psk: pskBytes,
        adm: admBytes,
        connector: unauthConnector,
      );

      await expectLater(
        client.connect(),
        throwsA(isA<RelayException>().having((e) => e.code, 'code', equals(4401))),
      );
    });

    test('handles 4503 relay busy or restarting close code', () async {
      Future<RelayWebSocket> busyConnector(Uri uri, {Iterable<String>? protocols}) async {
        final socket = MockRelayWebSocket();
        unawaited(() async {
          await for (final item in socket.outgoing) {
            if (item is String) {
              socket.deliverClose(4503, 'restarting');
              break;
            }
          }
        }());
        return socket;
      }

      final client = PhoneRelayClient(
        descriptor: validDescriptor,
        psk: pskBytes,
        adm: admBytes,
        connector: busyConnector,
      );

      await expectLater(
        client.connect(),
        throwsA(isA<RelayException>().having((e) => e.code, 'code', equals(4503))),
      );
    });

    test('handles 4001 handshake rejected close code', () async {
      Future<RelayWebSocket> rejectedConnector(Uri uri, {Iterable<String>? protocols}) async {
        final socket = MockRelayWebSocket();
        unawaited(() async {
          await for (final item in socket.outgoing) {
            if (item is String) {
              socket.deliver(jsonEncode({'t': 'ready'}));
            } else if (item is List<int>) {
              socket.deliverClose(4001, 'handshake rejected');
              break;
            }
          }
        }());
        return socket;
      }

      final client = PhoneRelayClient(
        descriptor: validDescriptor,
        psk: pskBytes,
        adm: admBytes,
        connector: rejectedConnector,
      );

      await expectLater(
        client.connect(),
        throwsA(isA<RelayException>().having((e) => e.code, 'code', equals(4001))),
      );
    });
  });
}
