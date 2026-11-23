import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:convert/convert.dart';
import 'package:nibble/core/e2e/crypto.dart';
import 'package:nibble/core/e2e/credentials.dart';

void main() {
  final vectorFile = File('../companion/src/e2e/vectors/v1.json');
  final vectors = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;

  group('V1 Cryptographic Primitives', () {
    test('P-256 Point Validation', () {
      final points = (vectors['V1']['points'] as List).cast<Map<String, dynamic>>();
      for (final p in points) {
        final bytes = Uint8List.fromList(hex.decode(p['hex'] as String));
        final isValid = P256.validatePublicKey(bytes);
        expect(isValid, equals(p['valid']), reason: 'Point test failed: ${p['name']}');
      }
    });

    test('P-256 ECDH matches vector DH(es) and DH(ee)', () {
      final privEs = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));
      final pubEs = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final sharedEs = P256.computeSecret(privEs, pubEs);
      expect(hex.encode(sharedEs), equals(vectors['V1']['dh']['es']));
      expect(hex.encode(P256.ecdh(privEs, pubEs)), equals(vectors['V1']['dh']['es']));

      final pubEe = Uint8List.fromList(hex.decode(vectors['V1']['computerEphemeralPublic'] as String));
      final sharedEe = P256.computeSecret(privEs, pubEe);
      expect(hex.encode(sharedEe), equals(vectors['V1']['dh']['ee']));
    });

    test('Credentials derivation: psk, adm, admHash', () {
      final creds = (vectors['V1']['credentials'] as List).cast<Map<String, dynamic>>();
      final keyId = Uint8List.fromList(hex.decode(vectors['V1']['keyId'] as String));
      final hostId = Uint8List.fromList(hex.decode(vectors['inputs']['hostId'] as String));

      for (final c in creds) {
        final token = c['token'] as String;
        final ch = credentialHash(token);
        expect(hex.encode(ch), equals(c['credHash']));

        final derivedPsk = derivePsk(ch, keyId);
        expect(hex.encode(derivedPsk), equals(c['psk']));
        expect(hex.encode(psk(ch, keyId)), equals(c['psk']));

        final derivedAdm = deriveAdmission(ch, hostId);
        expect(hex.encode(derivedAdm), equals(c['adm']));
        expect(hex.encode(admission(ch, hostId)), equals(c['adm']));
        expect(b64u(derivedAdm), equals(c['admB64u']));
        expect(admissionHash(derivedAdm), equals(c['admHash']));
      }
    });

    test('Base64url strict roundtrip and invalid input handling', () {
      final sample = Uint8List.fromList([0, 1, 2, 250, 255]);
      final encoded = b64u(sample);
      expect(fromB64u(encoded), equals(sample));

      expect(fromB64u(''), equals(Uint8List(0)));
      expect(fromB64u('A'), isNull);
      expect(fromB64u('$encoded='), isNull);
      expect(fromB64u('invalid+characters/=='), isNull);
    });

    test('AesGcm256 encrypt/decrypt roundtrip and authentication', () {
      final key = Uint8List(32)..fillRange(0, 32, 0x42);
      final nonce = Uint8List(12)..fillRange(0, 12, 0x01);
      final ad = Uint8List.fromList(utf8.encode('associated data'));
      final plaintext = Uint8List.fromList(utf8.encode('hello openmausbot'));

      final ciphertext = AesGcm256.encrypt(
        key: key,
        nonce: nonce,
        plaintext: plaintext,
        associatedData: ad,
      );

      expect(ciphertext.length, equals(plaintext.length + 16));

      final decrypted = AesGcm256.decrypt(
        key: key,
        nonce: nonce,
        ciphertext: ciphertext,
        associatedData: ad,
      );
      expect(decrypted, equals(plaintext));

      expect(
        () => AesGcm256.decrypt(
          key: key,
          nonce: nonce,
          ciphertext: ciphertext.sublist(0, ciphertext.length - 1),
          associatedData: ad,
        ),
        throwsA(isA<Exception>()),
      );

      final tampered = Uint8List.fromList(ciphertext);
      tampered[0] ^= 0x01;
      expect(
        () => AesGcm256.decrypt(
          key: key,
          nonce: nonce,
          ciphertext: tampered,
          associatedData: ad,
        ),
        throwsA(isA<Exception>()),
      );

      expect(
        () => AesGcm256.decrypt(
          key: key,
          nonce: nonce,
          ciphertext: ciphertext,
          associatedData: Uint8List.fromList(utf8.encode('wrong ad')),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('HkdfSha256 extract and expand', () {
      final ikm = Uint8List.fromList(utf8.encode('input key material'));
      final salt = Uint8List.fromList(utf8.encode('salt'));
      final info = Uint8List.fromList(utf8.encode('info'));

      final prk = HkdfSha256.extract(salt: salt, ikm: ikm);
      expect(prk.length, equals(32));

      final okm = HkdfSha256.expand(prk: prk, info: info, length: 64);
      expect(okm.length, equals(64));

      final okmShort = HkdfSha256.expand(prk: prk, info: info, length: 32);
      expect(okm.sublist(0, 32), equals(okmShort));
    });

    test('keyId derivation matches vector', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final expectedKeyId = vectors['V1']['keyId'] as String;
      expect(hex.encode(keyId(tPub)), equals(expectedKeyId));
    });

    test('sameBytes performs constant-time equality check', () {
      expect(sameBytes(Uint8List.fromList([1, 2, 3]), Uint8List.fromList([1, 2, 3])), isTrue);
      expect(sameBytes(Uint8List.fromList([1, 2, 3]), Uint8List.fromList([1, 2, 4])), isFalse);
      expect(sameBytes(Uint8List.fromList([1, 2, 3]), Uint8List.fromList([1, 2])), isFalse);
    });

    test('P-256 key pair generation and public key derivation', () {
      final privEs = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));
      final pubEs = P256.publicKeyFromPrivate(privEs);
      expect(hex.encode(pubEs), equals(vectors['V1']['phoneEphemeralPublic']));

      final kp = P256.generateKeyPair();
      expect(kp.privateKey.length, equals(32));
      expect(kp.publicKey.length, equals(65));
      expect(P256.validatePublicKey(kp.publicKey), isTrue);
    });
  });
}
