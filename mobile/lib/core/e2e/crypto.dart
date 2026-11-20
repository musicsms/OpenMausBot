import 'dart:math';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

BigInt _decodeBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

final BigInt _p256P = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);
final BigInt _p256A = _p256P - BigInt.from(3);
final BigInt _p256B = BigInt.parse(
  '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
  radix: 16,
);
final ECDomainParameters _p256Domain = ECDomainParameters('secp256r1');

class P256KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;

  const P256KeyPair({required this.privateKey, required this.publicKey});
}

class P256 {
  static const int publicKeyLength = 65;
  static const int privateKeyLength = 32;

  static bool validatePublicKey(Uint8List bytes) {
    if (bytes.length != publicKeyLength) return false;
    if (bytes[0] != 0x04) return false;

    final x = _decodeBigInt(bytes.sublist(1, 33));
    final y = _decodeBigInt(bytes.sublist(33, 65));

    if (x < BigInt.zero || x >= _p256P) return false;
    if (y < BigInt.zero || y >= _p256P) return false;

    final lhs = (y * y) % _p256P;
    final rhs = ((x * x * x) + (_p256A * x) + _p256B) % _p256P;

    return lhs == rhs;
  }

  static Uint8List computeSecret(Uint8List privateKey, Uint8List publicKey) {
    if (!validatePublicKey(publicKey)) {
      throw ArgumentError('Invalid P-256 public key');
    }
    if (privateKey.length != privateKeyLength) {
      throw ArgumentError('P-256 private key must be 32 bytes');
    }

    final d = _decodeBigInt(privateKey);
    if (d <= BigInt.zero || d >= _p256Domain.n) {
      throw ArgumentError('P-256 private key scalar out of range');
    }

    final x = _decodeBigInt(publicKey.sublist(1, 33));
    final y = _decodeBigInt(publicKey.sublist(33, 65));
    final point = _p256Domain.curve.createPoint(x, y);
    final pubKey = ECPublicKey(point, _p256Domain);
    final privKey = ECPrivateKey(d, _p256Domain);

    final agreement = ECDHBasicAgreement()..init(privKey);
    final secretInt = agreement.calculateAgreement(pubKey);

    final secretHex = secretInt.toRadixString(16).padLeft(64, '0');
    return Uint8List.fromList(hex.decode(secretHex));
  }

  static Uint8List ecdh(Uint8List privateKey, Uint8List publicKey) =>
      computeSecret(privateKey, publicKey);

  static Uint8List publicKeyFromPrivate(Uint8List privateKey) {
    if (privateKey.length != privateKeyLength) {
      throw ArgumentError('P-256 private key must be 32 bytes');
    }
    final d = _decodeBigInt(privateKey);
    if (d <= BigInt.zero || d >= _p256Domain.n) {
      throw ArgumentError('P-256 private key scalar out of range');
    }
    final q = _p256Domain.G * d;
    return q!.getEncoded(false);
  }

  static P256KeyPair generateKeyPair() {
    final rng = Random.secure();
    while (true) {
      final bytes = Uint8List(privateKeyLength);
      for (var i = 0; i < privateKeyLength; i++) {
        bytes[i] = rng.nextInt(256);
      }
      final d = _decodeBigInt(bytes);
      if (d > BigInt.zero && d < _p256Domain.n) {
        final pub = publicKeyFromPrivate(bytes);
        return P256KeyPair(privateKey: bytes, publicKey: pub);
      }
    }
  }
}

class AesGcm256 {
  static const int keyLength = 32;
  static const int nonceLength = 12;
  static const int tagLength = 16;

  static Uint8List encrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    Uint8List? associatedData,
  }) {
    if (key.length != keyLength) {
      throw ArgumentError('AES-256 key must be 32 bytes');
    }
    if (nonce.length != nonceLength) {
      throw ArgumentError('AES-GCM nonce must be 12 bytes');
    }

    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
      KeyParameter(key),
      tagLength * 8,
      nonce,
      associatedData ?? Uint8List(0),
    );
    cipher.init(true, params);

    final output = Uint8List(cipher.getOutputSize(plaintext.length));
    var len = cipher.processBytes(plaintext, 0, plaintext.length, output, 0);
    len += cipher.doFinal(output, len);
    return output.sublist(0, len);
  }

  static Uint8List decrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    Uint8List? associatedData,
  }) {
    if (key.length != keyLength) {
      throw ArgumentError('AES-256 key must be 32 bytes');
    }
    if (nonce.length != nonceLength) {
      throw ArgumentError('AES-GCM nonce must be 12 bytes');
    }
    if (ciphertext.length < tagLength) {
      throw ArgumentError('Ciphertext must include a 16-byte authentication tag');
    }

    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
      KeyParameter(key),
      tagLength * 8,
      nonce,
      associatedData ?? Uint8List(0),
    );
    cipher.init(false, params);

    final output = Uint8List(cipher.getOutputSize(ciphertext.length));
    var len = cipher.processBytes(ciphertext, 0, ciphertext.length, output, 0);
    len += cipher.doFinal(output, len);
    return output.sublist(0, len);
  }

  static Uint8List seal(
    Uint8List key,
    Uint8List nonce,
    Uint8List ad,
    Uint8List plaintext,
  ) =>
      encrypt(key: key, nonce: nonce, plaintext: plaintext, associatedData: ad);

  static Uint8List open(
    Uint8List key,
    Uint8List nonce,
    Uint8List ad,
    Uint8List ciphertext,
  ) =>
      decrypt(
        key: key,
        nonce: nonce,
        ciphertext: ciphertext,
        associatedData: ad,
      );
}

class HkdfSha256 {
  static const int hashLength = 32;

  static Uint8List extract({
    required Uint8List salt,
    required Uint8List ikm,
  }) {
    final effectiveSalt = salt.isEmpty ? Uint8List(hashLength) : salt;
    final hmac = crypto.Hmac(crypto.sha256, effectiveSalt);
    return Uint8List.fromList(hmac.convert(ikm).bytes);
  }

  static Uint8List expand({
    required Uint8List prk,
    required Uint8List info,
    required int length,
  }) {
    if (length > 255 * hashLength) {
      throw ArgumentError('Length cannot exceed ${255 * hashLength} bytes');
    }
    final n = (length + hashLength - 1) ~/ hashLength;
    final hmac = crypto.Hmac(crypto.sha256, prk);
    final okm = BytesBuilder(copy: false);
    var t = Uint8List(0);

    for (var i = 1; i <= n; i++) {
      final input = BytesBuilder(copy: false)
        ..add(t)
        ..add(info)
        ..addByte(i);
      t = Uint8List.fromList(hmac.convert(input.takeBytes()).bytes);
      okm.add(t);
    }

    return Uint8List.fromList(okm.takeBytes().sublist(0, length));
  }

  static List<Uint8List> derive({
    required Uint8List chainingKey,
    required Uint8List ikm,
    required int outputs,
  }) {
    final prk = extract(salt: chainingKey, ikm: ikm);
    final okm = expand(
      prk: prk,
      info: Uint8List(0),
      length: outputs * hashLength,
    );
    final result = <Uint8List>[];
    for (var i = 0; i < outputs; i++) {
      result.add(
        Uint8List.fromList(
          okm.sublist(i * hashLength, (i + 1) * hashLength),
        ),
      );
    }
    return result;
  }

  static List<Uint8List> hkdf(
    Uint8List chainingKey,
    Uint8List ikm,
    int outputs,
  ) =>
      derive(chainingKey: chainingKey, ikm: ikm, outputs: outputs);
}

List<Uint8List> hkdf(Uint8List chainingKey, Uint8List ikm, int outputs) =>
    HkdfSha256.derive(chainingKey: chainingKey, ikm: ikm, outputs: outputs);
