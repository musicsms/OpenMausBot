import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:convert/convert.dart';
import 'package:mobile/core/e2e/crypto.dart';
import 'package:mobile/core/e2e/noise.dart';

void main() {
  final vectorFile = File('../companion/src/e2e/vectors/v1.json');
  final vectors = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;

  group('V2 Noise Handshake Trace', () {
    test('Handshake generates exact message 1 and processes message 2', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][0]['psk'] as String));
      final ephemeralPriv = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));
      final trace = <Map<String, dynamic>>[];

      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: vectors['V2']['transport'] as int,
        fixedEphemeralPrivate: ephemeralPriv,
        trace: trace,
      );

      final msg1 = session.writeMessage1(
        payload: utf8.encode(vectors['inputs']['payload1'] as String),
      );

      final expectedMsg1 = vectors['V2']['message1'] as String;
      expect(hex.encode(msg1), equals(expectedMsg1));

      final msg2Hex = vectors['V2']['message2'] as String;
      final payload2 = session.readMessage2(Uint8List.fromList(hex.decode(msg2Hex)));
      expect(utf8.decode(payload2), equals(vectors['inputs']['payload2'] as String));
      expect(session.isComplete, isTrue);

      expect(hex.encode(session.kPc), equals(vectors['V2']['kPc']));
      expect(hex.encode(session.kCp), equals(vectors['V2']['kCp']));
      expect(hex.encode(session.handshakeHash), equals(vectors['V2']['handshakeHash']));

      final expectedTrace = (vectors['V2']['trace'] as List).cast<Map<String, dynamic>>();
      expect(trace.length, equals(expectedTrace.length));
      for (var i = 0; i < trace.length; i++) {
        expect(trace[i]['step'], equals(expectedTrace[i]['step']));
        expect(trace[i]['h'], equals(expectedTrace[i]['h']));
        expect(trace[i]['ck'], equals(expectedTrace[i]['ck']));
        expect(trace[i]['k'], equals(expectedTrace[i]['k']));
      }
    });
  });

  group('V3 Noise Handshake Trace', () {
    test('Handshake generates exact message 1 and processes message 2 for direct transport', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][1]['psk'] as String));
      final ephemeralPriv = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));
      final trace = <Map<String, dynamic>>[];

      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: vectors['V3']['transport'] as int,
        fixedEphemeralPrivate: ephemeralPriv,
        trace: trace,
      );

      final msg1 = session.writeMessage1(
        payload: utf8.encode(vectors['inputs']['payload1'] as String),
      );

      final expectedMsg1 = vectors['V3']['message1'] as String;
      expect(hex.encode(msg1), equals(expectedMsg1));

      final msg2Hex = vectors['V3']['message2'] as String;
      final payload2 = session.readMessage2(Uint8List.fromList(hex.decode(msg2Hex)));
      expect(utf8.decode(payload2), equals(vectors['inputs']['payload2'] as String));
      expect(session.isComplete, isTrue);

      expect(hex.encode(session.kPc), equals(vectors['V3']['kPc']));
      expect(hex.encode(session.kCp), equals(vectors['V3']['kCp']));
      expect(hex.encode(session.handshakeHash), equals(vectors['V3']['handshakeHash']));

      final expectedTrace = (vectors['V3']['trace'] as List).cast<Map<String, dynamic>>();
      expect(trace.length, equals(expectedTrace.length));
      for (var i = 0; i < trace.length; i++) {
        expect(trace[i]['step'], equals(expectedTrace[i]['step']));
        expect(trace[i]['h'], equals(expectedTrace[i]['h']));
        expect(trace[i]['ck'], equals(expectedTrace[i]['ck']));
        expect(trace[i]['k'], equals(expectedTrace[i]['k']));
      }
    });
  });

  group('V4 Transport Records', () {
    test('Encodes and decodes transport records matching V4 test vectors', () {
      final kPc = Uint8List.fromList(hex.decode(vectors['V4']['kPc'] as String));
      final kCp = Uint8List.fromList(hex.decode(vectors['V4']['kCp'] as String));

      final phoneSend = RecordCipher(CipherState(key: kPc));
      final phoneReceive = RecordCipher(CipherState(key: kCp));
      final compSend = RecordCipher(CipherState(key: kCp));
      final compReceive = RecordCipher(CipherState(key: kPc));

      final records = (vectors['V4']['records'] as List).cast<Map<String, dynamic>>();
      for (final r in records) {
        final direction = r['direction'] as String;
        final n = r['n'] as int;
        final frame = Uint8List.fromList(hex.decode(r['frame'] as String));
        final expectedRecord = r['record'] as String;

        if (direction == 'pc') {
          expect(phoneSend.nonce, equals(n));
          final sealed = phoneSend.seal(frame);
          expect(hex.encode(sealed), equals(expectedRecord));
          final opened = compReceive.open(Uint8List.fromList(hex.decode(expectedRecord)));
          expect(opened, equals(frame));
        } else {
          expect(compSend.nonce, equals(n));
          final sealed = compSend.seal(frame);
          expect(hex.encode(sealed), equals(expectedRecord));
          final opened = phoneReceive.open(Uint8List.fromList(hex.decode(expectedRecord)));
          expect(opened, equals(frame));
        }
      }
    });

    test('TransportRecordCodec length-prefixed encoding and decoding roundtrip', () {
      final key = Uint8List(32)..fillRange(0, 32, 0x42);
      final sendCipher = RecordCipher(CipherState(key: key));
      final receiveCipher = RecordCipher(CipherState(key: Uint8List.fromList(key)));

      final sendCodec = TransportRecordCodec(sendCipher);
      final receiveCodec = TransportRecordCodec(receiveCipher);
      final plain = Uint8List.fromList(utf8.encode('hello transport record'));

      final encoded = sendCodec.encode(plain);
      expect(encoded.length, equals(2 + plain.length + 16));

      final decoded = receiveCodec.decode(encoded);
      expect(decoded, equals(plain));
      expect(sendCodec.nonce, equals(1));
      expect(receiveCodec.nonce, equals(1));
    });

    test('TransportRecordCodec decode validates record length', () {
      final key = Uint8List(32)..fillRange(0, 32, 0x55);
      final codec = TransportRecordCodec(RecordCipher(CipherState(key: key)));

      expect(() => codec.decode(Uint8List(1)), throwsA(isA<NoiseError>()));

      final truncated = Uint8List.fromList([0x00, 0x10, 0x01, 0x02]);
      expect(() => codec.decode(truncated), throwsA(isA<NoiseError>()));
    });
  });

  group('Handshake and Record Limits & Security Errors', () {
    test('Rejects invalid transport public key', () {
      final invalidPub = Uint8List(65);
      final psk = Uint8List(32);
      expect(
        () => NoiseInitiatorSession(
          transportPublicKey: invalidPub,
          psk: psk,
          prologueByte: 1,
        ),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'bad_point')),
      );
    });

    test('Rejects invalid PSK length', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      expect(
        () => NoiseInitiatorSession(
          transportPublicKey: tPub,
          psk: Uint8List(16),
          prologueByte: 1,
        ),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'bad_psk')),
      );
    });

    test('Caps payload 1 length before processing', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][0]['psk'] as String));
      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: 1,
      );

      final oversized = Uint8List(maxHandshakePayload + 1);
      expect(
        () => session.writeMessage1(payload: oversized),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'payload_too_large')),
      );
    });

    test('Rejects message 2 with invalid size', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][0]['psk'] as String));
      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: 1,
      );
      session.writeMessage1(payload: utf8.encode('{}'));

      expect(
        () => session.readMessage2(Uint8List(50)),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'message2_size')),
      );
      expect(
        () => session.readMessage2(Uint8List(maxHandshakeMessage + 1)),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'message2_size')),
      );
    });

    test('Rejects reading message 2 twice or before message 1', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][0]['psk'] as String));
      final ephemeralPriv = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));

      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: 1,
        fixedEphemeralPrivate: ephemeralPriv,
      );

      expect(
        () => session.readMessage2(Uint8List(81)),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'not_started')),
      );

      session.writeMessage1(payload: utf8.encode(vectors['inputs']['payload1'] as String));
      final msg2Hex = vectors['V2']['message2'] as String;
      session.readMessage2(Uint8List.fromList(hex.decode(msg2Hex)));

      expect(
        () => session.readMessage2(Uint8List.fromList(hex.decode(msg2Hex))),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'finished')),
      );
    });

    test('Rejects message 2 when conn does not match', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][0]['psk'] as String));
      final ephemeralPriv = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));

      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: 1,
        fixedEphemeralPrivate: ephemeralPriv,
        conn: 'mismatched_conn_value',
      );

      session.writeMessage1(payload: utf8.encode(vectors['inputs']['payload1'] as String));
      final msg2Hex = vectors['V2']['message2'] as String;
      expect(
        () => session.readMessage2(Uint8List.fromList(hex.decode(msg2Hex))),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'payload2_conn')),
      );
    });

    test('Rejects record plaintext and ciphertext exceeding size limits', () {
      final key = Uint8List(32);
      final cipher = RecordCipher(CipherState(key: key));

      final oversizedPlain = Uint8List(maxRecordPlaintext + 1);
      expect(
        () => cipher.seal(oversizedPlain),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'record_too_large')),
      );

      final oversizedRecord = Uint8List(maxRecordBytes + 1);
      expect(
        () => cipher.open(oversizedRecord),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'record_too_large')),
      );
    });

    test('Rejects message 2 with invalid ephemeral public key re', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][0]['psk'] as String));
      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: 1,
      );
      session.writeMessage1(payload: utf8.encode(vectors['inputs']['payload1'] as String));

      final invalidReMessage2 = Uint8List(publicKeyBytes + tagBytes);
      expect(
        () => session.readMessage2(invalidReMessage2),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'bad_point')),
      );
    });

    test('Rejects message 2 when conn is unset in session', () {
      final tPriv = Uint8List.fromList(hex.decode(vectors['inputs']['transportPrivate'] as String));
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][0]['psk'] as String));
      final ephemeralPriv = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));
      final compEphemeralPriv = Uint8List.fromList(hex.decode(vectors['inputs']['computerEphemeralPrivate'] as String));
      final compE = P256KeyPair(
        privateKey: compEphemeralPriv,
        publicKey: P256.publicKeyFromPrivate(compEphemeralPriv),
      );

      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: 1,
        fixedEphemeralPrivate: ephemeralPriv,
      );
      final rawPayload1 = Uint8List(16);
      final msg1 = session.writeMessage1(payload: rawPayload1);

      final respState = SymmetricState.initialize();
      respState.mixHash(prologue(1));
      respState.mixHash(tPub);
      respState.mixKeyAndHash(psk);
      final phonePub = Uint8List.sublistView(msg1, 0, publicKeyBytes);
      respState.mixHash(phonePub);
      respState.mixKey(phonePub);
      final es = P256.computeSecret(tPriv, phonePub);
      respState.mixKey(es);
      respState.decryptAndHash(Uint8List.sublistView(msg1, publicKeyBytes));

      respState.mixHash(compE.publicKey);
      respState.mixKey(compE.publicKey);
      final ee = P256.computeSecret(compE.privateKey, phonePub);
      respState.mixKey(ee);
      final payload2Bytes = utf8.encode(jsonEncode({'v': 1, 'conn': 'some_conn'}));
      final c2 = respState.encryptAndHash(Uint8List.fromList(payload2Bytes));
      final msg2 = Uint8List(publicKeyBytes + c2.length)
        ..setRange(0, publicKeyBytes, compE.publicKey)
        ..setRange(publicKeyBytes, publicKeyBytes + c2.length, c2);

      expect(
        () => session.readMessage2(msg2),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'payload2_conn')),
      );
    });

    test('Rejects message 2 when version is not 1', () {
      final tPriv = Uint8List.fromList(hex.decode(vectors['inputs']['transportPrivate'] as String));
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][0]['psk'] as String));
      final ephemeralPriv = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));
      final compEphemeralPriv = Uint8List.fromList(hex.decode(vectors['inputs']['computerEphemeralPrivate'] as String));
      final compE = P256KeyPair(
        privateKey: compEphemeralPriv,
        publicKey: P256.publicKeyFromPrivate(compEphemeralPriv),
      );

      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: 1,
        fixedEphemeralPrivate: ephemeralPriv,
        conn: 'some_conn',
      );
      final msg1 = session.writeMessage1(payload: utf8.encode('{"v":1,"conn":"some_conn"}'));

      final respState = SymmetricState.initialize();
      respState.mixHash(prologue(1));
      respState.mixHash(tPub);
      respState.mixKeyAndHash(psk);
      final phonePub = Uint8List.sublistView(msg1, 0, publicKeyBytes);
      respState.mixHash(phonePub);
      respState.mixKey(phonePub);
      final es = P256.computeSecret(tPriv, phonePub);
      respState.mixKey(es);
      respState.decryptAndHash(Uint8List.sublistView(msg1, publicKeyBytes));

      respState.mixHash(compE.publicKey);
      respState.mixKey(compE.publicKey);
      final ee = P256.computeSecret(compE.privateKey, phonePub);
      respState.mixKey(ee);
      final payload2Bytes = utf8.encode(jsonEncode({'v': 2, 'conn': 'some_conn'}));
      final c2 = respState.encryptAndHash(Uint8List.fromList(payload2Bytes));
      final msg2 = Uint8List(publicKeyBytes + c2.length)
        ..setRange(0, publicKeyBytes, compE.publicKey)
        ..setRange(publicKeyBytes, publicKeyBytes + c2.length, c2);

      expect(
        () => session.readMessage2(msg2),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'payload2_version')),
      );
    });

    test('encodePayload1 validates conn length and app length limit', () {
      final validConn = Uint8List(connBytes);
      expect(
        () => encodePayload1(conn: Uint8List(connBytes - 1), app: 'test'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => encodePayload1(conn: validConn, app: 'a' * (maxAppChars + 1)),
        throwsA(isA<ArgumentError>()),
      );

      final encoded = encodePayload1(conn: validConn, app: 'a' * maxAppChars);
      final json = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
      expect(json['v'], equals(1));
      expect(json['app'], equals('a' * maxAppChars));
    });

    test('Stops session when nonce counter reaches limit', () {
      final key = Uint8List(32);
      final cipher = RecordCipher(CipherState(key: key, n: nonceLimit - 1));
      final sealed = cipher.seal(Uint8List.fromList([1, 2, 3]));

      final receiveCipher = RecordCipher(CipherState(key: key, n: nonceLimit - 1));
      final opened = receiveCipher.open(sealed);
      expect(opened, equals(Uint8List.fromList([1, 2, 3])));

      expect(
        () => cipher.seal(Uint8List.fromList([4, 5, 6])),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'nonce_exhausted')),
      );
      expect(
        () => receiveCipher.open(sealed),
        throwsA(predicate((e) => e is NoiseError && e.reason == 'nonce_exhausted')),
      );
    });
  });
}
